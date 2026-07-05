import Foundation
import Testing
@testable import Soul_Desktop

struct SoulWorkProjectionTests {
    @Test func workProjectionPayloadDecodesContinuitySnapshot() throws {
        let data = Data("""
        {
          "schema": "soul-work-projection/v1",
          "project_key": "soul",
          "session_id": "simple-session",
          "generated_at": "2026-07-04T16:00:00Z",
          "projection_fingerprint": "sha256:abc123",
          "active_task": {
            "task_id": "SOUL-SOUL-307",
            "id": "SOUL-SOUL-307",
            "project": "soul",
            "subject": "Build semantic projection",
            "status": "in_progress",
            "done_criteria": ["projection works"],
            "completed_criteria": []
          },
          "active_run": {
            "run_id": "run_projection",
            "project": "soul",
            "task_id": "SOUL-SOUL-307",
            "session_id": "simple-session",
            "objective": "Read projection",
            "status": "running",
            "updated_at": "2026-07-04T15:59:00Z"
          },
          "trajectory_status": {
            "schema": "soul-trajectory-status/v1",
            "project_key": "soul",
            "session_id": "simple-session",
            "exists": true,
            "stale": false,
            "trajectory_status": "compiled",
            "compiled_at": "2026-07-04T15:58:00Z"
          },
          "trajectory": {
            "status": "compiled",
            "primary_intent": "Continue central registry work.",
            "compiled_at": "2026-07-04T15:58:00Z",
            "compiler_version": "semantic-trajectory/v1",
            "turn_count": 4,
            "decision_count": 1,
            "verification": {
              "run": ["verify-run"],
              "passed": ["verify-pass"],
              "failed": []
            },
            "eval_candidate_refs": ["eval-1"]
          },
          "semantic_timeline_tail": [
            {
              "semantic_event_id": "sem-1",
              "semantic_seq": 1,
              "checkpoint": "PlanCommitted",
              "timestamp": "2026-07-04T15:57:00Z",
              "actor": "user",
              "summary": "Pull work_projection.get.",
              "confidence": 0.8,
              "refs": ["hooks:1"]
            }
          ],
          "next_step": "Pull work_projection.get."
        }
        """.utf8)

        let projection = try JSONDecoder().decode(SoulWorkProjection.self, from: data)

        #expect(projection.schema == "soul-work-projection/v1")
        #expect(projection.projectKey == "soul")
        #expect(projection.sessionID == "simple-session")
        #expect(projection.projectionFingerprint == "sha256:abc123")
        #expect(projection.activeTask?.id == "SOUL-SOUL-307")
        #expect(projection.activeRun?.runID == "run_projection")
        #expect(projection.trajectoryStatus?.stale == false)
        #expect(projection.trajectory?.primaryIntent == "Continue central registry work.")
        #expect(projection.trajectory?.verification?.run == ["verify-run"])
        #expect(projection.trajectory?.verification?.passed == ["verify-pass"])
        #expect(projection.trajectory?.verification?.failed == [])
        #expect(projection.semanticTimelineTail.first?.checkpoint == "PlanCommitted")
        #expect(projection.nextStep == "Pull work_projection.get.")
    }

    @Test func workProjectionUpdatedParamsDriveTargetedRefresh() throws {
        let data = Data("""
        {
          "schema": "soul-work-projection-update/v1",
          "project_key": "soul-desktop",
          "session_id": "session-123",
          "source": "session.finalize",
          "status": "finalized",
          "updated_at": "2026-07-04T16:04:00Z",
          "projection_fingerprint": "sha256:new",
          "trajectory_status": {
            "schema": "soul-trajectory-status/v1",
            "project_key": "soul-desktop",
            "session_id": "session-123",
            "exists": true,
            "stale": true,
            "reason": "hooks_changed"
          },
          "next_step": "Recompile the semantic trajectory before continuing from central projection."
        }
        """.utf8)

        let params = try JSONDecoder().decode(SoulWorkProjectionUpdatedParams.self, from: data)
        let request = try #require(SoulRunStore.workProjectionRefreshRequest(
            from: params,
            project: "soul-desktop",
            lastFingerprint: "sha256:old"
        ))

        #expect(params.schema == "soul-work-projection-update/v1")
        #expect(params.source == "session.finalize")
        #expect(params.trajectoryStatus?.stale == true)
        #expect(request.sessionID == "session-123")
        #expect(request.projectionFingerprint == "sha256:new")
        #expect(SoulRunStore.workProjectionRefreshRequest(
            from: params,
            project: "soul-desktop",
            lastFingerprint: "sha256:new"
        ) == nil)
        #expect(SoulRunStore.workProjectionRefreshRequest(
            from: params,
            project: "other-project",
            lastFingerprint: "sha256:old"
        ) == nil)
    }

    @Test func workProjectionUpdatedParamsRefreshMissingFingerprintAndPreserveProjectionError() throws {
        let data = Data("""
        {
          "schema": "soul-work-projection-update/v1",
          "project_key": "soul-desktop",
          "session_id": "session-123",
          "source": "registry.watch",
          "status": "changed",
          "updated_at": "2026-07-04T16:05:00Z",
          "projection_fingerprint": "",
          "projection_error": {
            "code": "unsafe_path_segment",
            "message": "session_id is not safe"
          }
        }
        """.utf8)

        let params = try JSONDecoder().decode(SoulWorkProjectionUpdatedParams.self, from: data)
        let request = try #require(SoulRunStore.workProjectionRefreshRequest(
            from: params,
            project: "soul-desktop",
            lastFingerprint: "sha256:old"
        ))

        #expect(request.sessionID == "session-123")
        #expect(request.projectionFingerprint == "")
        #expect(request.projectionError?.code == "unsafe_path_segment")
        #expect(request.projectionError?.message == "session_id is not safe")
    }
}
