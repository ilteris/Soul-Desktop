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
}
