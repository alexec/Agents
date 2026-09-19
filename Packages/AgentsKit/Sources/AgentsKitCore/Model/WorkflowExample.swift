import Foundation

/// The sentence the app offers a person who has no workflows yet.
///
/// A workflow is written by asking an agent for one, and the whole difficulty of a
/// first one is not knowing what asking for it sounds like. The empty state on a
/// project page offers this, and tapping it puts it in the prompt rather than sending
/// it, the same as any suggestion the agent itself makes.
///
/// It says a time, because a schedule is the trigger that needs no other agent to
/// exist first, and it says what to do in one clause, because the prompt that reaches
/// the workflow is what the person is really writing here.
///
/// Kept in the shared half so the live runtime test can ask each runtime this exact
/// sentence. What the app puts in front of somebody and what the test proves works
/// have to be the same words, or the test is about a prompt nobody sends.
public enum WorkflowExample {
    /// What the empty state offers, and what `Live/WorkflowToolLiveTests` sends.
    ///
    /// It names the tool, which reads oddly in a sentence meant for a person, and it
    /// is there because the live runs said so. "Set up a workflow that runs every
    /// weekday at 9am" sent two of the four runtimes somewhere else entirely: Claude
    /// scheduled it with its own cron, and Copilot wrote a GitHub Actions file. The
    /// word is theirs as much as ours, and the only thing that settles which one is
    /// meant is naming the tool.
    public static let prompt = """
        Use the manage_workflows tool to set up a workflow that runs every weekday at \
        9am and tells me whether the build is green.
        """

    /// The schedule that sentence describes: weekdays, on the hour, 9am to 9am.
    ///
    /// Here rather than in the test because it is the other half of the same claim —
    /// change the sentence and this is what has to change with it.
    public static let schedule = WorkflowSchedule(minutes: [0], hours: 9...9,
                                                  days: Weekday.weekdays)
}
