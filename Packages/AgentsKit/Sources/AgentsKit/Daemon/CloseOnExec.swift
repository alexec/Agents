import Foundation

/// Keep a descriptor out of the children.
///
/// The daemon spawns runtimes and login shells all day, and a child inherits every
/// descriptor that is not marked to close. That is how a dead daemon goes on holding
/// its own lock: the shells it started outlive it, keep its `flock` open, and every
/// daemon after that finds the lock taken and exits believing another one is already
/// running — silently, because that is the ordinary case when two windows race.
///
/// So the rule here is that nothing the daemon owns for its own sake is inherited.
/// Where a flag can be asked for at the moment the descriptor is made, it is; this is
/// for the calls that have nowhere to put one.
@discardableResult
func setCloseOnExec(_ descriptor: Int32) -> Bool {
    guard descriptor >= 0 else { return false }
    let flags = fcntl(descriptor, F_GETFD)
    guard flags >= 0 else { return false }
    return fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
}

/// Whether a descriptor will be closed when this process execs. Here for the tests,
/// which is the only way to check a flag that only shows itself in a child.
func isCloseOnExec(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFD)
    return flags >= 0 && (flags & FD_CLOEXEC) != 0
}
