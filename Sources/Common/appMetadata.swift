public let stableAeroSpaceAppId: String = "com.denizmaral.MarSpace"
#if DEBUG
    public let aeroSpaceAppId: String = "com.denizmaral.MarSpace.debug"
    public let aeroSpaceAppName: String = "MarSpace-Debug"
#else
    public let aeroSpaceAppId: String = stableAeroSpaceAppId
    public let aeroSpaceAppName: String = "MarSpace" // Based on AeroSpace (MIT). The CLI keeps AeroSpace's name and commands
#endif
