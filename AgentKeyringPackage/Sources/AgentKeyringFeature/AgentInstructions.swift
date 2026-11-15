/// The one line agents should carry in AGENTS.md or CLAUDE.md, shown in the
/// app's setup panel. It points at the bundled skill, which holds the details.
public enum AgentInstructions {
    public static let snippet =
        "When you need one of my logins, use the agent-keyring command. Run `agent-keyring --help` to see how. Never ask me to type a password."
}
