import AgentKeyringFeature

/// Synthetic attribution for isolated policy tests. Never used by the app listener.
public let syntheticRequester = AgentRequester(name: "Fixture agent", processIdentifier: 100,
    processStartTime: HarnessProcessStartTime(seconds: 1_000, microseconds: 123),
    workingDirectory: "/tmp", machineName: "Fixture Mac", networkAddress: "192.0.2.1")
