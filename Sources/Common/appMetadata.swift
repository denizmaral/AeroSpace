public let stableAeroSpaceAppId: String = "bobko.aerospace"
#if DEBUG
    public let aeroSpaceAppId: String = "bobko.aerospace.debug"
    public let aeroSpaceAppName: String = "MarSpace-Debug"
#else
    public let aeroSpaceAppId: String = stableAeroSpaceAppId
    public let aeroSpaceAppName: String = "MarSpace" // A fork of AeroSpace (MIT). The bundle id and the CLI name are kept for compatibility
#endif
