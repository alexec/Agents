# SpeechTranscriber against DictationTranscriber (#2515)

Date: 2026-10-23. The switch is Apple's newer on-device `SpeechTranscriber`. No Whisper. No cloud transcription.

## What was measured

Nothing on a microphone. This lane has no recording of a person, and it did not run either transcriber on audio. A number from the Mac's `say` command would measure that voice, not dictation. The figures below are empty on purpose.

Word error rate, when someone runs it: the reference is the script. Split both sides on spaces. Count a substitution, an insertion, and a deletion as one each. Divide by the number of words in the reference.

| Model | Words | Errors | Word error rate |
|---|---|---|---|
| `DictationTranscriber` (the old one) |  |  |  |
| `SpeechTranscriber` (this change) |  |  |  |

## The script

Twenty sentences. They use the words the transcriber is seeded with.

1. Open the GitHub issue and tell me what is left.
2. The GitLab pipeline failed on the last commit.
3. Ship the Remote build to TestFlight.
4. Put this change in a worktree and open a pull request.
5. Which lane is on the voice mode issue?
6. What is in the open milestone?
7. Run the merge wave when the checks are green.
8. Ask the Scrum Master which issue is next.
9. The control plane lost the host. What does the log say?
10. Start a Claude session on the prompt bar.
11. Start a Codex session in this worktree.
12. Copilot left a review. Read it and answer it.
13. Cursor is on the sidebar mark. Do not edit those files.
14. Grok should switch the transcriber and seed the words.
15. OpenCode is not installed on this Mac. Say what to install.
16. Gemini and Antigravity are runtimes this app can start.
17. Archive the finished sessions in this project.
18. The dictate button should underline the words it is still hearing.
19. If those words come late, show a listening pulse.
20. These words were dictated, so a word that sounds the same may be wrong.

## How the live words behave

`SpeechTranscriber` is asked for volatile results, and the field underlines them. The first volatile result is compared with the audio time it covers. If it arrives more than 1.2 seconds after that audio, the underline stays off for the rest of that listen and the microphone button pulses instead. A later revision of the same words does not count: those are expected to arrive after the first guess.
