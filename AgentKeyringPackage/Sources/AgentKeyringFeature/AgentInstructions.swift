/// The one line agents should carry in AGENTS.md or CLAUDE.md, shown in the
/// app's setup panel. It points at the bundled skill, which holds the details.
public enum AgentInstructions {
    public static let snippet =
        "For website logins and two-factor codes saved in Apple Passwords, use agent-keyring. Run `agent-keyring skill` first, and never ask the user to type a password."
}
