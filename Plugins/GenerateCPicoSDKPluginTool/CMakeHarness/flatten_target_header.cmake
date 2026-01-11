# Flatten a header using -D / -I from a target and its link libraries
#
# Usage:
#   flatten_target_header(
#       <TARGET_NAME>
#       <INPUT_HEADER>       # e.g. ${CMAKE_SOURCE_DIR}/includes.h
#       <OUTPUT_HEADER>      # e.g. ${CMAKE_BINARY_DIR}/PublicAPI.flattened.h
#   )
#
# It will:
#   - Flatten project + pico SDK headers  (-I ...)
#   - Keep toolchain/system headers as plain includes  (-idirafter ...)

function(flatten_target_header TARGET_NAME INPUT_HEADER OUTPUT_HEADER)
    # ----------------------------
    # Collect -D and -I recursively
    # ----------------------------

    set(_queue ${TARGET_NAME})
    set(_visited "")
    set(_all_defs "")
    set(_all_incs "")

    while(_queue)
        list(POP_FRONT _queue _t)

        if(NOT TARGET ${_t})
            continue()
        endif()

        list(FIND _visited "${_t}" _idx)
        if(NOT _idx EQUAL -1)
            continue()  # already visited
        endif()
        list(APPEND _visited "${_t}")

        # Local + interface compile definitions
        get_target_property(_defs_local ${_t} COMPILE_DEFINITIONS)
        get_target_property(_defs_iface ${_t} INTERFACE_COMPILE_DEFINITIONS)

        if(_defs_local)
            list(APPEND _all_defs ${_defs_local})
        endif()
        if(_defs_iface)
            list(APPEND _all_defs ${_defs_iface})
        endif()

        # Local + interface include dirs
        get_target_property(_incs_local ${_t} INCLUDE_DIRECTORIES)
        get_target_property(_incs_iface ${_t} INTERFACE_INCLUDE_DIRECTORIES)

        if(_incs_local)
            list(APPEND _all_incs ${_incs_local})
        endif()
        if(_incs_iface)
            list(APPEND _all_incs ${_incs_iface})
        endif()

        # Follow link graph (normal + interface)
        get_target_property(_links_local ${_t} LINK_LIBRARIES)
        get_target_property(_links_iface ${_t} INTERFACE_LINK_LIBRARIES)

        if(_links_local)
            list(APPEND _queue ${_links_local})
        endif()
        if(_links_iface)
            list(APPEND _queue ${_links_iface})
        endif()
    endwhile()

    # Remove generator-expression entries (contain "$<...")
    set(_filtered_defs "")
    foreach(_d ${_all_defs})
        string(FIND "${_d}" "$<" _has_gen)
        if(_has_gen EQUAL -1)
            list(APPEND _filtered_defs "${_d}")
        endif()
    endforeach()

    set(_filtered_incs "")
    foreach(_i ${_all_incs})
        string(FIND "${_i}" "$<" _has_gen)
        if(_has_gen EQUAL -1)
            list(APPEND _filtered_incs "${_i}")
        endif()
    endforeach()

    list(REMOVE_DUPLICATES _filtered_defs)
    list(REMOVE_DUPLICATES _filtered_incs)

    # ----------------------------
    # Build -D flags
    # ----------------------------
    set(_def_flags "")
    foreach(_d ${_filtered_defs})
        list(APPEND _def_flags -D${_d})
    endforeach()

    # ----------------------------
    # Split includes into:
    #   -I (project + pico SDK)
    #   -idirafter (toolchain / system / others)
    # ----------------------------

    # PICO_SDK_PATH is set by pico_sdk_import.cmake; guard if not defined
    if(DEFINED PICO_SDK_PATH)
        get_filename_component(_pico_sdk_root "${PICO_SDK_PATH}" ABSOLUTE)
    else()
        set(_pico_sdk_root "")
    endif()

    set(_inc_flags_primary "")
    set(_inc_flags_after   "")

    foreach(_i ${_filtered_incs})
        if(NOT _i)
            continue()
        endif()

        get_filename_component(_abs_i "${_i}" ABSOLUTE)

        # Decide whether to flatten this dir
        #   - under source dir  -> flatten
        #   - under build dir   -> flatten
        #   - under PICO_SDK_PATH -> flatten
        #   - everything else   -> preserve with -idirafter
        set(_is_flatten_inc FALSE)

        string(FIND "${_abs_i}" "${CMAKE_SOURCE_DIR}" _pos_src)
        if(_pos_src EQUAL 0)
            set(_is_flatten_inc TRUE)
        endif()

        if(NOT _is_flatten_inc)
            string(FIND "${_abs_i}" "${CMAKE_BINARY_DIR}" _pos_bin)
            if(_pos_bin EQUAL 0)
                set(_is_flatten_inc TRUE)
            endif()
        endif()

        if(NOT _is_flatten_inc AND _pico_sdk_root)
            string(FIND "${_abs_i}" "${_pico_sdk_root}" _pos_pico)
            if(_pos_pico EQUAL 0)
                set(_is_flatten_inc TRUE)
            endif()
        endif()

        if(_is_flatten_inc)
            list(APPEND _inc_flags_primary -I${_abs_i})
        else()
            list(APPEND _inc_flags_after -idirafter ${_abs_i})
        endif()
    endforeach()

    # ----------------------------
    # Preprocess with that env
    # ----------------------------
    add_custom_command(
        OUTPUT  ${OUTPUT_HEADER}
        COMMAND ${CMAKE_C_COMPILER}
                -E -P -dD -x c-header
                ${_def_flags}
                ${_inc_flags_primary}
                ${_inc_flags_after}
                ${INPUT_HEADER}
                -o ${OUTPUT_HEADER}
        DEPENDS ${INPUT_HEADER}
        COMMENT "Flattening ${INPUT_HEADER} -> ${OUTPUT_HEADER}"
        VERBATIM
    )

    add_custom_target(${TARGET_NAME}_flatten_header
        DEPENDS ${OUTPUT_HEADER}
    )
endfunction()
