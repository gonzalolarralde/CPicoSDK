@globalActor
public actor CPU0Actor {
    public static let shared = CPU0Actor()
}

@globalActor
public actor CPU1Actor {
    public static let shared = CPU1Actor()
}

@globalActor
public actor MainActor {
    public static let shared = MainActor()
}
