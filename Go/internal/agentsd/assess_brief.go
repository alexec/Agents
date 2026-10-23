package agentsd

import (
	"strconv"
	"strings"
)

// assessThrowaway is the workflow the agent writes and removes (step workflows): it never
// runs, since nothing moves the branch it waits for, and starts waiting for an OK besides.
const assessThrowaway = "---\nname: Assessment throwaway\non:\n  - " + assessNeverEvent + ":\n      branch: " + assessNeverBranch +
	"\nagent: new\n---\nReply with the word OK."

// assessBrief is the prompt the assessing agent starts with (RuntimeAssessment.brief): the
// same steps as the assess-runtime skill.
func assessBrief(runtimeID, runtimeName string, model, runtimeVersion *string, host, reportPath, scopePath,
	escalationTool, shortID, date string) string {
	modelWords := "its default model"
	if model != nil {
		modelWords = "model `" + *model + "`"
	}
	ownAsk := "Your runtime has no question tool the app can carry. Ask nothing here; write `not offered` for this step."
	if escalationTool != "" {
		ownAsk = "Ask one question with your runtime's own question tool, `" + escalationTool + "`, not the app's `ask_question` (the agents server's): \"Is this assessment running unattended?\" with the options Yes and No. " +
			"It is one of your runtime's built-in tools, not one of the app's, so look for it among those; " +
			"call it rather than deciding from a list that it is missing, and if the call is refused, put its words in the report."
	}
	version := "not given by its adapter"
	if runtimeVersion != nil {
		version = "`" + *runtimeVersion + "`"
	}
	var content []string
	for _, l := range strings.Split(assessThrowaway, "\n") {
		content = append(content, "    "+l)
	}
	lease := "assess-" + shortID
	return strings.NewReplacer(
		"{{runtimeName}}", runtimeName, "{{runtimeID}}", runtimeID, "{{date}}", date, "{{version}}", version, "{{host}}", host,
		"{{reportPath}}", reportPath, "{{scopePath}}", scopePath, "{{lease}}", lease, "{{pingLease}}", lease+"-ping",
		"{{pingEvent}}", assessPingEvent, "{{workflow}}", lease, "{{fileContent}}", strings.Join(content, "\n"),
		"{{never}}", "`wait_for_event` on `"+assessNeverEvent+"` where `{\"branch\": \""+assessNeverBranch+"\"}`",
		"{{longWaitMinutes}}", strconv.Itoa(assessLongWait), "{{ownAsk}}", ownAsk, "{{modelWords}}", modelWords,
		"{{helperLabel}}", assessHelperLabel,
	).Replace(assessTemplate)
}
