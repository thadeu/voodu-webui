# 08 — Flaky TestPodExec_HonoursTTYInteractiveAndWinsize in CI

Status: needs-triage
Priority: P4
Repo: clowk-voodu
Blocked by: —

CI for 9a72f9f (v0.18.34) failed on `internal/controller` with
`api_exec_test.go:165: TTY should propagate when ?tty=true; got false` (plus
Interactive and winsize 0x0). The change did not touch pod exec. The test passes
30× in a row alone with -race; a CI re-run of the failed job passed. Likely
shared state or timing when the whole package runs in parallel. Find what the
test shares with its neighbours (a package-level fake, a global) and isolate it.
