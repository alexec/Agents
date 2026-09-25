import Testing

/// Every suite that runs the fake ssh (037): each test starts real processes — ssh
/// masters, a Python relay, a daemon on the "server" — and waits on them with deadlines.
/// Run side by side they starve each other and the rest of the suite, so they sit under
/// this one parent and `.serialized` takes them one test at a time, all five together.
@Suite("Servers over the fake ssh", .serialized)
enum FakeSSHSuites {}
