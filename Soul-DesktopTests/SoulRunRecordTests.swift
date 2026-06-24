import Foundation
import Testing
@testable import Soul_Desktop

struct SoulRunRecordTests {
    @Test func runHistoryPayloadDecodesDurableRunFields() throws {
        let data = Data("""
        {
          "project": "soul-desktop",
          "filters": {
            "status": null,
            "task_id": null,
            "skill": null,
            "failure_reason": null
          },
          "runs": [
            {
              "run_id": "run_ui_001",
              "project": "soul-desktop",
              "task_id": "SOUL-SOUL_DESKTOP-301",
              "objective": "wire desktop run visibility",
              "status": "completed",
              "created_at": "2026-06-19T17:00:00Z",
              "updated_at": "2026-06-19T17:01:00Z",
              "completed_at": "2026-06-19T17:02:00Z",
              "summary": "Runs appear in the project story.",
              "duration_sec": 120.0,
              "retry_count": 2,
              "failure_reasons": ["first verifier failed"],
              "skill_ids": ["swiftui-patterns"],
              "verifier_outcomes": {"failed": 1, "completed": 1},
              "file": "/tmp/registry/runs/soul-desktop/run_ui_001/run.json"
            }
          ]
        }
        """.utf8)

        let payload = try JSONDecoder().decode(SoulRunHistoryPayload.self, from: data)
        let run = try #require(payload.runs.first)

        #expect(payload.project == "soul-desktop")
        #expect(run.id == "run_ui_001")
        #expect(run.taskID == "SOUL-SOUL_DESKTOP-301")
        #expect(run.status == "completed")
        #expect(run.retryCount == 2)
        #expect(run.failureReasons == ["first verifier failed"])
        #expect(run.skillIDs == ["swiftui-patterns"])
        #expect(run.verifierOutcomes["completed"] == 1)
        #expect(run.isActive == false)
        #expect(run.timestamp != nil)
        #expect(run.displayTitle == "SOUL-SOUL_DESKTOP-301 run")
        #expect(run.displayDetail.contains("2 retries"))
    }

    @Test func runReviewPayloadDecodesSummaryAndEmptyRuns() throws {
        let data = Data("""
        {
          "schema": "soul-run-review/v1",
          "project": "soul-desktop",
          "filters": {
            "status": null,
            "task_id": null,
            "skill": null,
            "failure_reason": null,
            "limit": 5
          },
          "summary": {
            "total_runs": 4,
            "completed_runs": 3,
            "failed_runs": 1,
            "success_rate": 0.75,
            "average_duration_sec": 32.5,
            "retry_count": 1,
            "failure_reasons": {"timeout": 1},
            "verifier_outcomes": {"completed": 3, "failed": 1}
          },
          "runs": []
        }
        """.utf8)

        let payload = try JSONDecoder().decode(SoulRunReviewPayload.self, from: data)

        #expect(payload.project == "soul-desktop")
        #expect(payload.summary.totalRuns == 4)
        #expect(payload.summary.completedRuns == 3)
        #expect(payload.summary.failedRuns == 1)
        #expect(payload.summary.successRate == 0.75)
        #expect(payload.summary.averageDurationSeconds == 32.5)
        #expect(payload.summary.retryCount == 1)
        #expect(payload.summary.failureReasons["timeout"] == 1)
        #expect(payload.summary.verifierOutcomes["failed"] == 1)
    }

    @Test func runStepListPayloadDecodesStepSummaries() throws {
        let data = Data("""
        {
          "project": "soul-desktop",
          "run_id": "run_ui_001",
          "steps": [
            {
              "step_id": "iter_001_verifier_001",
              "run_id": "run_ui_001",
              "project": "soul-desktop",
              "kind": "verifier",
              "objective": "run smoke checks",
              "status": "completed",
              "created_at": "2026-06-19T17:00:00Z",
              "updated_at": "2026-06-19T17:01:00Z",
              "completed_at": "2026-06-19T17:01:00Z",
              "summary": "Build passed.",
              "artifact_ref": "steps/iter_001_verifier_001.json",
              "file": "/tmp/registry/runs/soul-desktop/run_ui_001/steps/iter_001_verifier_001.json"
            }
          ]
        }
        """.utf8)

        let payload = try JSONDecoder().decode(SoulRunStepListPayload.self, from: data)
        let step = try #require(payload.steps.first)

        #expect(payload.runID == "run_ui_001")
        #expect(step.id == "iter_001_verifier_001")
        #expect(step.kind == "verifier")
        #expect(step.status == "completed")
        #expect(step.summary == "Build passed.")
    }

    @Test func workStatusPayloadDecodesTaskAndRuns() throws {
        let data = Data("""
        {
          "project": "soul-desktop",
          "task": {
            "task_id": "SOUL-SOUL_DESKTOP-428",
            "id": "SOUL-SOUL_DESKTOP-428",
            "project": "soul-desktop",
            "subject": "Harden Soul Desktop against current Soul CLI contracts",
            "status": "in_progress",
            "raw_status": "in_progress",
            "priority": "medium",
            "category": "feature",
            "done_criteria": ["Task status mutations use soul task set-status with --task-id."],
            "completed_criteria": [],
            "file": "/tmp/registry/tasks/soul-desktop/SOUL-SOUL_DESKTOP-428.json",
            "is_active": true
          },
          "runs": [
            {
              "run_id": "run_20260623050916_9511e7",
              "project": "soul-desktop",
              "task_id": "SOUL-SOUL_DESKTOP-428",
              "session_id": "019ef2d7-d1f9-76f2-9b8f-b67602b29a9c",
              "objective": "Update Soul Desktop command calls and tests.",
              "status": "running",
              "created_at": "2026-06-23T05:09:16.156199Z",
              "updated_at": "2026-06-23T05:09:16.156199Z",
              "file": "/tmp/registry/runs/soul-desktop/run_20260623050916_9511e7/run.json"
            }
          ]
        }
        """.utf8)

        let payload = try JSONDecoder().decode(SoulWorkStatusPayload.self, from: data)
        let task = try #require(payload.task)
        let run = try #require(payload.runs.first)

        #expect(payload.project == "soul-desktop")
        #expect(task.id == "SOUL-SOUL_DESKTOP-428")
        #expect(task.subject == "Harden Soul Desktop against current Soul CLI contracts")
        #expect(task.doneCriteria.count == 1)
        #expect(task.isActive == true)
        #expect(run.isActive)
        #expect(run.project == "soul-desktop")
    }

    @Test func runEventsPayloadDecodesStepPointers() throws {
        let data = Data("""
        {
          "project": "soul-desktop",
          "run_id": "run_20260622020107_9b97fe",
          "events": [
            {
              "event": "RunStarted",
              "timestamp": "2026-06-22T02:01:07.459815Z",
              "run_id": "run_20260622020107_9b97fe",
              "task_id": "SOUL-SOUL_DESKTOP-382",
              "status": "running"
            },
            {
              "event": "StepCompleted",
              "timestamp": "2026-06-22T02:09:40.283731Z",
              "run_id": "run_20260622020107_9b97fe",
              "step_id": "verify_20260622020938",
              "status": "completed",
              "attempt_count": 1,
              "output_ref": "artifacts/verify_20260622020938/result.json",
              "artifact_ref": "/tmp/registry/runs/soul-desktop/run/steps/verify.json"
            }
          ]
        }
        """.utf8)

        let payload = try JSONDecoder().decode(SoulRunEventsPayload.self, from: data)
        let completed = try #require(payload.events.last)

        #expect(payload.project == "soul-desktop")
        #expect(payload.runID == "run_20260622020107_9b97fe")
        #expect(completed.stepID == "verify_20260622020938")
        #expect(completed.attemptCount == 1)
        #expect(completed.outputRef == "artifacts/verify_20260622020938/result.json")
    }

    @Test func subagentListPayloadDecodesActiveAndCompletedRecords() throws {
        let data = Data("""
        {
          "project": "soul-desktop",
          "subagents": [
            {
              "subagent_id": "delegate_registry_guardian_ab12cd34",
              "project": "soul-desktop",
              "specialist": "registry_guardian",
              "status": "running",
              "started_at": 1782191520.0,
              "live_log": "/tmp/subagents/delegate_registry_guardian_ab12cd34/live.log",
              "live_log_bytes": 2165,
              "finding_path": "/tmp/subagents/delegate_registry_guardian_ab12cd34/finding.json",
              "finding": {
                "specialist": "registry_guardian",
                "provider": "codex",
                "task": "Review the orchestration contract.",
                "status": "completed",
                "summary": "Auditing task/run/subagent state.",
                "timestamp": "2026-06-23T05:13:00Z"
              }
            }
          ]
        }
        """.utf8)

        let payload = try JSONDecoder().decode(SoulSubagentListPayload.self, from: data)
        let subagent = try #require(payload.subagents.first)

        #expect(payload.project == "soul-desktop")
        #expect(subagent.id == "delegate_registry_guardian_ab12cd34")
        #expect(subagent.displayTitle == "@registry_guardian")
        #expect(subagent.displayDetail == "Auditing task/run/subagent state.")
        #expect(subagent.isActive)
        #expect(subagent.liveLogBytes == 2165)
        #expect(subagent.timestamp != nil)
        #expect(subagent.findingPath?.hasSuffix("finding.json") == true)
        #expect(subagent.finding?.provider == "codex")
    }

    @Test func orchestrationStatusResultDecodesDaemonSnapshot() throws {
        let data = Data("""
        {
          "project_key": "soul-desktop",
          "snapshot": {
            "schema": "soul-orchestration-snapshot/v1",
            "project": "soul-desktop",
            "project_key": "soul-desktop",
            "version": "abc123",
            "updated_at": "2026-06-24T06:30:00Z",
            "work_status": {
              "project": "soul-desktop",
              "task": {
                "task_id": "SOUL-SOUL_DESKTOP-428",
                "id": "SOUL-SOUL_DESKTOP-428",
                "project": "soul-desktop",
                "subject": "Harden Soul Desktop against current Soul CLI contracts",
                "status": "in_progress",
                "done_criteria": ["daemon snapshot"],
                "completed_criteria": [],
                "file": "/tmp/registry/tasks/soul-desktop/SOUL-SOUL_DESKTOP-428.json",
                "is_active": true
              },
              "runs": [
                {
                  "run_id": "run-active",
                  "project": "soul-desktop",
                  "task_id": "SOUL-SOUL_DESKTOP-428",
                  "objective": "Wire app server.",
                  "status": "running",
                  "updated_at": "2026-06-24T06:29:00Z"
                }
              ]
            },
            "run_review": {
              "schema": "soul-run-review/v1",
              "project": "soul-desktop",
              "filters": {"limit": 25},
              "summary": {
                "total_runs": 2,
                "completed_runs": 1,
                "failed_runs": 0,
                "success_rate": 0.5,
                "average_duration_sec": 4.0,
                "retry_count": 0,
                "failure_reasons": {},
                "verifier_outcomes": {"completed": 1}
              },
              "runs": [
                {
                  "run_id": "run-active",
                  "project": "soul-desktop",
                  "task_id": "SOUL-SOUL_DESKTOP-428",
                  "status": "running",
                  "updated_at": "2026-06-24T06:29:00Z"
                },
                {
                  "run_id": "run-complete",
                  "project": "soul-desktop",
                  "task_id": "SOUL-SOUL_DESKTOP-400",
                  "status": "completed",
                  "updated_at": "2026-06-24T06:00:00Z"
                }
              ]
            },
            "subagent_list": {
              "project": "soul-desktop",
              "subagents": [
                {
                  "subagent_id": "sub-123",
                  "project": "soul-desktop",
                  "live_log": "/tmp/subagents/sub-123/live.log",
                  "live_log_bytes": 42,
                  "started_at": 1782191520.0,
                  "status": "in_progress",
                  "finding_path": "/tmp/del_registry_guardian.json",
                  "finding": {
                    "specialist": "registry_guardian",
                    "summary": "Reviewing the daemon contract.",
                    "timestamp": "2026-06-24T06:31:00Z"
                  }
                }
              ]
            },
            "active_task": {
              "task_id": "SOUL-SOUL_DESKTOP-428",
              "id": "SOUL-SOUL_DESKTOP-428",
              "project": "soul-desktop",
              "subject": "Harden Soul Desktop against current Soul CLI contracts",
              "status": "in_progress",
              "done_criteria": [],
              "completed_criteria": []
            },
            "runs": [
              {
                "run_id": "run-active",
                "project": "soul-desktop",
                "task_id": "SOUL-SOUL_DESKTOP-428",
                "status": "running"
              }
            ],
            "subagents": [
              {
                "subagent_id": "sub-123",
                "project": "soul-desktop",
                "status": "in_progress",
                "finding": {
                  "specialist": "registry_guardian",
                  "summary": "Reviewing the daemon contract."
                }
              }
            ]
          }
        }
        """.utf8)

        let result = try JSONDecoder().decode(SoulOrchestrationStatusResult.self, from: data)

        #expect(result.projectKey == "soul-desktop")
        #expect(result.snapshot.schema == "soul-orchestration-snapshot/v1")
        #expect(result.snapshot.version == "abc123")
        #expect(result.snapshot.workStatus.task?.id == "SOUL-SOUL_DESKTOP-428")
        #expect(result.snapshot.workStatus.runs.map(\.runID) == ["run-active"])
        #expect(result.snapshot.runReview.summary.totalRuns == 2)
        #expect(result.snapshot.runReview.runs.map(\.runID) == ["run-active", "run-complete"])
        #expect(result.snapshot.subagentList.subagents.first?.displayDetail == "Reviewing the daemon contract.")
    }

    @Test func orchestrationUpdatedParamsDecodeInvalidationOnlyPayload() throws {
        let data = Data("""
        {
          "project_key": "soul-desktop",
          "version": "version-2",
          "file_count": 12,
          "updated_at": "2026-06-24T06:35:00Z",
          "scope": "orchestration"
        }
        """.utf8)

        let params = try JSONDecoder().decode(SoulOrchestrationUpdatedParams.self, from: data)

        #expect(params.projectKey == "soul-desktop")
        #expect(params.version == "version-2")
        #expect(params.fileCount == 12)
        #expect(params.scope == "orchestration")
    }
}
