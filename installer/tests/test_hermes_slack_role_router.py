import tempfile
import unittest
from pathlib import Path
import sys
import os
import json
import asyncio

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "installer" / "lib"))

from hermes_slack_role_router import (
    DEFAULT_GROUPS,
    DEFAULT_ROLES,
    JsonThreadStateStore,
    RouterConfig,
    SQLiteMissionStore,
    SlackRuntime,
    SlackRoleRouter,
    _socket_mode_connected,
    _terminate_process_group,
    load_config_from_env,
    redact_secrets,
    sanitized_subprocess_env,
)


class SlackRoleRouterTests(unittest.TestCase):
    def make_router(self, allowed_users=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cfg = RouterConfig(
            roles=DEFAULT_ROLES,
            groups=DEFAULT_GROUPS,
            allowed_users=set(allowed_users or {"U_OK"}),
            allow_all=False,
            allowed_channels={"C123"},
            state_path=Path(tmp.name) / "state.json",
            audit_path=Path(tmp.name) / "audit.jsonl",
            queue_path=Path(tmp.name) / "queue.sqlite",
            health_path=Path(tmp.name) / "health.json",
        )
        return SlackRoleRouter(cfg, state_store=JsonThreadStateStore(cfg.state_path))

    def test_dm_without_role_routes_to_manager(self):
        router = self.make_router()
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_OK",
                "ts": "100.1",
                "text": "what should I do next?",
            },
            bot_user_id="UBOT",
        )

        self.assertTrue(decision.should_process)
        self.assertEqual(decision.kind, "role")
        self.assertEqual(decision.roles, ["hermes_manager"])
        self.assertEqual(decision.message_text, "what should I do next?")

    def test_dm_role_prefix_routes_to_matching_profile(self):
        router = self.make_router()
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_OK",
                "ts": "100.2",
                "text": "backend: sketch the API contract",
            },
            bot_user_id="UBOT",
        )

        self.assertTrue(decision.should_process)
        self.assertEqual(decision.roles, ["hermes_backend_engineer"])
        self.assertEqual(decision.display_names, ["Backend Engineer"])
        self.assertEqual(decision.message_text, "sketch the API contract")

    def test_channel_mention_with_role_replies_in_thread(self):
        router = self.make_router()
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "C123",
                "channel_type": "channel",
                "user": "U_OK",
                "ts": "200.1",
                "text": "<@UBOT> techlead choose the architecture",
            },
            bot_user_id="UBOT",
        )

        self.assertTrue(decision.should_process)
        self.assertEqual(decision.roles, ["hermes_techlead"])
        self.assertEqual(decision.thread_ts, "200.1")
        self.assertEqual(decision.message_text, "choose the architecture")

    def test_channel_mentions_require_allowed_channel(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cfg = RouterConfig(
            roles=DEFAULT_ROLES,
            groups=DEFAULT_GROUPS,
            allowed_users={"U_OK"},
            state_path=Path(tmp.name) / "state.json",
        )
        router = SlackRoleRouter(cfg, state_store=JsonThreadStateStore(cfg.state_path))
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "C999",
                "channel_type": "channel",
                "user": "U_OK",
                "ts": "200.9",
                "text": "<@UBOT> manager work here",
            },
            bot_user_id="UBOT",
        )

        self.assertFalse(decision.should_process)
        self.assertEqual(decision.reason, "channel_not_allowed")

    def test_active_thread_reply_without_mention_routes_to_existing_role(self):
        router = self.make_router()
        first = router.route_event(
            {
                "team": "T1",
                "channel": "C123",
                "channel_type": "channel",
                "user": "U_OK",
                "ts": "200.1",
                "text": "<@UBOT> qa test this",
            },
            bot_user_id="UBOT",
        )
        router.record_decision(first)

        follow_up = router.route_event(
            {
                "team": "T1",
                "channel": "C123",
                "channel_type": "channel",
                "user": "U_OK",
                "ts": "200.2",
                "thread_ts": "200.1",
                "text": "also cover the denied-user path",
            },
            bot_user_id="UBOT",
        )

        self.assertTrue(follow_up.should_process)
        self.assertEqual(follow_up.roles, ["hermes_qa_test_engineer"])
        self.assertTrue(follow_up.is_interjection)
        self.assertEqual(follow_up.thread_ts, "200.1")

    def test_group_prefix_routes_to_configured_mission_roles(self):
        router = self.make_router()
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_OK",
                "ts": "300.1",
                "text": "delivery: implement rate limiting",
            },
            bot_user_id="UBOT",
        )

        self.assertTrue(decision.should_process)
        self.assertEqual(decision.kind, "group")
        self.assertEqual(
            decision.roles,
            [
                "hermes_manager",
                "hermes_techlead",
                "hermes_backend_engineer",
                "hermes_qa_test_engineer",
                "hermes_reviewing_engineer",
            ],
        )

    def test_sre_routes_for_allowlisted_owner_operator_mode(self):
        router = self.make_router()
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_OK",
                "ts": "350.1",
                "text": "sre: deploy this",
            },
            bot_user_id="UBOT",
        )

        self.assertTrue(decision.should_process)
        self.assertEqual(decision.roles, ["hermes_sre_engineer"])
        self.assertEqual(decision.auth_level, "operator")

    def test_release_group_routes_for_allowlisted_owner_operator_mode(self):
        router = self.make_router()
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_OK",
                "ts": "350.2",
                "text": "release: ship this",
            },
            bot_user_id="UBOT",
        )

        self.assertTrue(decision.should_process)
        self.assertEqual(decision.kind, "group")
        self.assertEqual(
            decision.roles,
            [
                "hermes_manager",
                "hermes_qa_test_engineer",
                "hermes_sre_engineer",
                "hermes_incident_manager",
            ],
        )
        self.assertEqual(decision.auth_level, "operator")

    def test_allow_all_does_not_grant_operator_authority(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cfg = RouterConfig(
            roles=DEFAULT_ROLES,
            groups=DEFAULT_GROUPS,
            allowed_users=set(),
            allow_all=True,
            state_path=Path(tmp.name) / "state.json",
        )
        router = SlackRoleRouter(cfg, state_store=JsonThreadStateStore(cfg.state_path))

        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_ANY",
                "ts": "360.1",
                "text": "backend: change the system",
            },
            bot_user_id="UBOT",
        )

        self.assertFalse(decision.should_process)
        self.assertEqual(decision.reason, "operator_allowlist_required")

    def test_unknown_role_requests_clarification(self):
        router = self.make_router()
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_OK",
                "ts": "400.1",
                "text": "wizard: fix prod",
            },
            bot_user_id="UBOT",
        )

        self.assertFalse(decision.should_process)
        self.assertEqual(decision.reason, "unknown_target")
        self.assertIn("wizard", decision.notice)

    def test_unauthorized_user_is_denied_before_routing(self):
        router = self.make_router(allowed_users={"U_OK"})
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_BAD",
                "ts": "500.1",
                "text": "manager: do work",
            },
            bot_user_id="UBOT",
        )

        self.assertFalse(decision.should_process)
        self.assertEqual(decision.reason, "unauthorized")
        self.assertEqual(decision.roles, [])

    def test_bot_messages_are_ignored(self):
        router = self.make_router()
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "C123",
                "channel_type": "channel",
                "user": "UBOT",
                "bot_id": "B123",
                "ts": "600.1",
                "text": "<@UBOT> manager loop",
            },
            bot_user_id="UBOT",
        )

        self.assertFalse(decision.should_process)
        self.assertEqual(decision.reason, "bot_message")

    def test_load_config_reads_phase_38_flat_config_yaml(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cfg_path = Path(tmp.name) / "config.yaml"
        cfg_path.write_text(
            "\n".join(
                [
                    "SLACK_ALLOWED_USERS: U_ONE,U_TWO",
                    "SLACK_ALLOW_ALL_USERS: false",
                    "SLACK_ALLOWED_CHANNELS: C123,G456",
                    'HERMES_SLACK_ROLE_GROUPS: {"tiny":["manager","qa"]}',
                    "HERMES_SLACK_DEFAULT_ROLE: qa",
                ]
            ),
            encoding="utf-8",
        )
        old = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old)))
        os.environ.clear()
        os.environ["HERMES_CONFIG_PATH"] = str(cfg_path)

        cfg = load_config_from_env()

        self.assertEqual(cfg.allowed_users, {"U_ONE", "U_TWO"})
        self.assertFalse(cfg.allow_all)
        self.assertEqual(cfg.allowed_channels, {"C123", "G456"})
        self.assertEqual(cfg.groups["tiny"], ("manager", "qa"))
        self.assertEqual(cfg.default_role, "qa")

    def test_home_channel_is_allowed_channel(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cfg_path = Path(tmp.name) / "config.yaml"
        cfg_path.write_text(
            "\n".join(
                [
                    "SLACK_ALLOWED_USERS: U_ONE",
                    "SLACK_HOME_CHANNEL: C_HOME",
                ]
            ),
            encoding="utf-8",
        )
        old = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old)))
        os.environ.clear()
        os.environ["HERMES_CONFIG_PATH"] = str(cfg_path)

        cfg = load_config_from_env()

        self.assertEqual(cfg.allowed_channels, {"C_HOME"})

    def test_invalid_group_config_fails_fast(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cfg_path = Path(tmp.name) / "config.yaml"
        cfg_path.write_text(
            'HERMES_SLACK_ROLE_GROUPS: {"bad":["manager","wizard"]}',
            encoding="utf-8",
        )
        old = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old)))
        os.environ.clear()
        os.environ["HERMES_CONFIG_PATH"] = str(cfg_path)

        with self.assertRaises(ValueError):
            load_config_from_env()

    def test_default_role_alias_is_canonicalized(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cfg = RouterConfig(
            roles=DEFAULT_ROLES,
            groups=DEFAULT_GROUPS,
            allowed_users={"U_OK"},
            default_role="cos",
            state_path=Path(tmp.name) / "state.json",
        )

        router = SlackRoleRouter(cfg, state_store=JsonThreadStateStore(cfg.state_path))
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_OK",
                "ts": "700.1",
                "text": "status?",
            },
            bot_user_id="UBOT",
        )

        self.assertTrue(decision.should_process)
        self.assertEqual(decision.roles, ["hermes_manager"])

    def test_audit_hashes_raw_text_for_denied_event(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        audit_path = Path(tmp.name) / "audit.jsonl"
        cfg = RouterConfig(
            roles=DEFAULT_ROLES,
            groups=DEFAULT_GROUPS,
            allowed_users={"U_OK"},
            audit_path=audit_path,
            state_path=Path(tmp.name) / "state.json",
            queue_path=Path(tmp.name) / "queue.sqlite",
            health_path=Path(tmp.name) / "health.json",
        )
        router = SlackRoleRouter(cfg, state_store=JsonThreadStateStore(cfg.state_path))
        runtime = SlackRuntime(router, executor=None)  # type: ignore[arg-type]
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_BAD",
                "ts": "800.1",
                "text": "manager: denied text",
            },
            bot_user_id="UBOT",
        )

        runtime._audit(decision, event_id="E1", raw_text="manager: denied text")
        row = json.loads(audit_path.read_text(encoding="utf-8"))

        self.assertEqual(row["reason"], "unauthorized")
        self.assertNotEqual(row["input_digest"], "e3b0c44298fc1c14")

    def test_subprocess_env_scrubs_slack_tokens(self):
        old = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old)))
        os.environ.clear()
        os.environ.update(
            {
                "SLACK_BOT_TOKEN": "xoxb-secret",
                "SLACK_APP_TOKEN": "xapp-secret",
                "HERMES_SLACK_ALLOWED_USERS": "U_OK",
                "HERMES_LITELLM_KEY": "sk-allowed",
                "PATH": "/bin",
                "HOME": "/tmp",
            }
        )

        env = sanitized_subprocess_env()

        self.assertNotIn("SLACK_BOT_TOKEN", env)
        self.assertNotIn("SLACK_APP_TOKEN", env)
        self.assertNotIn("HERMES_SLACK_ALLOWED_USERS", env)
        self.assertIn("HERMES_LITELLM_KEY", env)

    def test_redact_secrets_removes_slack_and_api_keys(self):
        text = "tokens xoxb-abc-123 xapp-1-A-B sk-abcdefghijklmnop"

        redacted = redact_secrets(text)

        self.assertNotIn("xoxb-abc-123", redacted)
        self.assertNotIn("xapp-1-A-B", redacted)
        self.assertNotIn("sk-abcdefghijklmnop", redacted)

    def test_runtime_runs_group_sequence_and_posts_summaries(self):
        router = self.make_router()
        executor = FakeExecutor()
        posts = []

        async def poster(**kwargs):
            posts.append(kwargs)

        runtime = SlackRuntime(router, executor=executor, poster=poster, auto_process=False)

        asyncio.run(
            runtime.handle_event(
                {
                    "team": "T1",
                    "channel": "D123",
                    "channel_type": "im",
                    "user": "U_OK",
                    "ts": "900.1",
                    "text": "review: check this patch",
                },
                bot_user_id="UBOT",
                event_id="E900",
            )
        )

        self.assertEqual(executor.profiles, [])
        self.assertTrue(any("queued" in p["text"].lower() for p in posts))

        asyncio.run(runtime.process_queued())

        self.assertEqual(
            executor.profiles,
            ["hermes_techlead", "hermes_qa_test_engineer", "hermes_reviewing_engineer"],
        )
        self.assertTrue(any("Mission thread started" in p["text"] for p in posts))
        self.assertTrue(any("*Reviewing Engineer*" in p["text"] for p in posts))

    def test_runtime_deduplicates_events_across_restart(self):
        router = self.make_router()
        executor = FakeExecutor()
        runtime = SlackRuntime(router, executor=executor, poster=async_noop_poster, auto_process=False)
        event = {
            "team": "T1",
            "channel": "D123",
            "channel_type": "im",
            "user": "U_OK",
            "ts": "901.1",
            "text": "backend: one request",
        }

        asyncio.run(runtime.handle_event(event, bot_user_id="UBOT", event_id="E901"))
        asyncio.run(runtime.process_queued())

        restarted_executor = FakeExecutor()
        restarted_runtime = SlackRuntime(
            router,
            executor=restarted_executor,
            poster=async_noop_poster,
            auto_process=False,
        )
        asyncio.run(restarted_runtime.handle_event(event, bot_user_id="UBOT", event_id="E901"))
        asyncio.run(restarted_runtime.process_queued())

        self.assertEqual(executor.profiles, ["hermes_backend_engineer"])
        self.assertEqual(restarted_executor.profiles, [])

    def test_handle_event_acks_fast_without_running_executor_inline(self):
        router = self.make_router()
        executor = FakeExecutor()
        posts = []

        async def poster(**kwargs):
            posts.append(kwargs)

        runtime = SlackRuntime(router, executor=executor, poster=poster, auto_process=False)

        asyncio.run(
            runtime.handle_event(
                {
                    "team": "T1",
                    "channel": "D123",
                    "channel_type": "im",
                    "user": "U_OK",
                    "ts": "901.5",
                    "text": "backend: mutate reversible local state",
                },
                bot_user_id="UBOT",
                event_id="E9015",
            )
        )

        self.assertEqual(executor.profiles, [])
        self.assertTrue(any("queued" in p["text"].lower() for p in posts))

    def test_handle_event_does_not_await_slow_slack_post(self):
        router = self.make_router()
        executor = FakeExecutor()
        runtime = SlackRuntime(router, executor=executor, auto_process=False)

        async def run_event():
            await asyncio.wait_for(
                runtime.handle_event(
                    {
                        "team": "T1",
                        "channel": "D123",
                        "channel_type": "im",
                        "user": "U_OK",
                        "ts": "901.6",
                        "text": "backend: quick ack",
                    },
                    bot_user_id="UBOT",
                    event_id="E9016",
                    client=SlowSlackClient(),
                ),
                timeout=0.1,
            )

        asyncio.run(run_event())
        self.assertEqual(executor.profiles, [])

    def test_active_single_role_interjection_persists_as_followup(self):
        router = self.make_router()
        executor = BlockingExecutor()
        posts = []

        async def poster(**kwargs):
            posts.append(kwargs)

        runtime = SlackRuntime(router, executor=executor, poster=poster, auto_process=False)
        first = {
            "team": "T1",
            "channel": "D123",
            "channel_type": "im",
            "user": "U_OK",
            "ts": "903.1",
            "text": "backend: start a long task",
        }
        followup = {
            "team": "T1",
            "channel": "D123",
            "channel_type": "im",
            "user": "U_OK",
            "ts": "903.2",
            "thread_ts": "903.1",
            "text": "also include the migration rollback",
        }

        asyncio.run(runtime.handle_event(first, bot_user_id="UBOT", event_id="E9031"))

        async def run_with_interjection():
            worker = asyncio.create_task(runtime.process_queued())
            while executor.started is None:
                await asyncio.sleep(0)
            await executor.started.wait()
            await runtime.handle_event(followup, bot_user_id="UBOT", event_id="E9032")
            executor.release.set()
            await worker
            await runtime.process_queued()

        asyncio.run(run_with_interjection())

        self.assertEqual(
            executor.profiles,
            ["hermes_backend_engineer", "hermes_backend_engineer"],
        )
        self.assertTrue(any("Interjection noted" in p["text"] for p in posts))

    def test_runtime_posts_executor_failure_redacted(self):
        router = self.make_router()
        executor = FakeExecutor(error="boom xoxb-secret-token")
        posts = []

        async def poster(**kwargs):
            posts.append(kwargs)

        runtime = SlackRuntime(router, executor=executor, poster=poster, auto_process=False)

        asyncio.run(
            runtime.handle_event(
                {
                    "team": "T1",
                    "channel": "D123",
                    "channel_type": "im",
                    "user": "U_OK",
                    "ts": "902.1",
                    "text": "backend: fail please",
                },
                bot_user_id="UBOT",
                event_id="E902",
            )
        )

        asyncio.run(runtime.process_queued())

        rendered = "\n".join(p["text"] for p in posts)
        self.assertIn("Backend Engineer failed", rendered)
        self.assertNotIn("xoxb-secret-token", rendered)

        store = SQLiteMissionStore(router.config.queue_path, health_path=router.config.health_path)
        rows = store.jobs_for_test()
        self.assertEqual(rows[0]["status"], "failed")
        self.assertIn("boom", rows[0]["error"])

    def test_claim_next_is_atomic(self):
        router = self.make_router()
        store = SQLiteMissionStore(router.config.queue_path, health_path=router.config.health_path)
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_OK",
                "ts": "904.1",
                "text": "backend: one claim",
            },
            bot_user_id="UBOT",
        )
        store.enqueue(decision, event_id="E9041", raw_text="backend: one claim")

        first = store.claim_next()
        second = store.claim_next()

        self.assertIsNotNone(first)
        self.assertIsNone(second)

    def test_stale_running_jobs_are_marked_unknown_on_startup(self):
        router = self.make_router()
        store = SQLiteMissionStore(router.config.queue_path, health_path=router.config.health_path)
        decision = router.route_event(
            {
                "team": "T1",
                "channel": "D123",
                "channel_type": "im",
                "user": "U_OK",
                "ts": "904.2",
                "text": "backend: crash midway",
            },
            bot_user_id="UBOT",
        )
        store.enqueue(decision, event_id="E9042", raw_text="backend: crash midway")
        store.claim_next()

        SlackRuntime(router, executor=FakeExecutor(), poster=async_noop_poster, auto_process=False)
        recovered = SQLiteMissionStore(router.config.queue_path, health_path=router.config.health_path)
        rows = recovered.jobs_for_test()

        self.assertEqual(rows[0]["status"], "unknown_after_crash")

    def test_followup_interjection_prompt_keeps_original_context(self):
        router = self.make_router()
        executor = BlockingExecutor()
        runtime = SlackRuntime(router, executor=executor, poster=async_noop_poster, auto_process=False)
        first = {
            "team": "T1",
            "channel": "D123",
            "channel_type": "im",
            "user": "U_OK",
            "ts": "904.3",
            "text": "backend: design the migration",
        }
        followup = {
            "team": "T1",
            "channel": "D123",
            "channel_type": "im",
            "user": "U_OK",
            "ts": "904.4",
            "thread_ts": "904.3",
            "text": "also include rollback",
        }

        asyncio.run(runtime.handle_event(first, bot_user_id="UBOT", event_id="E9043"))

        async def run_with_interjection():
            worker = asyncio.create_task(runtime.process_queued())
            while executor.started is None:
                await asyncio.sleep(0)
            await executor.started.wait()
            await runtime.handle_event(followup, bot_user_id="UBOT", event_id="E9044")
            executor.release.set()
            await worker
            await runtime.process_queued()

        asyncio.run(run_with_interjection())

        self.assertIn("design the migration", executor.prompts[1])
        self.assertIn("also include rollback", executor.prompts[1])

    def test_mission_store_writes_health_with_queue_depth(self):
        router = self.make_router()
        store = SQLiteMissionStore(router.config.queue_path, health_path=router.config.health_path)

        store.write_health(
            bot_user_id="UBOT",
            connected=True,
            active_mission="mission-1",
            last_error="",
        )
        health = json.loads(router.config.health_path.read_text(encoding="utf-8"))

        self.assertEqual(health["bot_user_id"], "UBOT")
        self.assertTrue(health["connected"])
        self.assertEqual(health["active_mission"], "mission-1")
        self.assertEqual(health["queue_depth"], 0)

    def test_runtime_worker_does_not_mark_socket_connected_before_connect(self):
        router = self.make_router()
        runtime = SlackRuntime(
            router,
            executor=FakeExecutor(),
            poster=async_noop_poster,
            auto_process=False,
        )

        asyncio.run(runtime.process_queued())
        health = json.loads(router.config.health_path.read_text(encoding="utf-8"))

        self.assertFalse(health["connected"])

    def test_socket_mode_connected_uses_client_probe(self):
        class FakeSocketClient:
            async def is_connected(self):
                return True

        self.assertTrue(asyncio.run(_socket_mode_connected(FakeSocketClient())))
        self.assertFalse(asyncio.run(_socket_mode_connected(None)))

    def test_terminate_process_group_stops_child_processes(self):
        async def run_child():
            proc = await asyncio.create_subprocess_exec(
                "/bin/sh",
                "-c",
                "sleep 30 & wait",
                start_new_session=True,
            )
            await asyncio.sleep(0.1)
            await _terminate_process_group(proc)
            return proc.returncode

        self.assertIsNotNone(asyncio.run(run_child()))


class FakeExecutor:
    def __init__(self, error=None):
        self.error = error
        self.profiles = []
        self.prompts = []

    async def run(self, profile, prompt):
        self.profiles.append(profile)
        self.prompts.append(prompt)
        if self.error:
            raise RuntimeError(self.error)
        return f"response from {profile}"


class BlockingExecutor(FakeExecutor):
    def __init__(self):
        super().__init__()
        self.started = None
        self.release = None

    async def run(self, profile, prompt):
        self.profiles.append(profile)
        self.prompts.append(prompt)
        loop = asyncio.get_running_loop()
        if self.started is None:
            self.started = asyncio.Event()
            self.release = asyncio.Event()
            self.started.set()
            await self.release.wait()
        return f"response from {profile}"


async def async_noop_poster(**kwargs):
    return None


class SlowSlackClient:
    async def chat_postMessage(self, **kwargs):
        await asyncio.sleep(5)


if __name__ == "__main__":
    unittest.main()
