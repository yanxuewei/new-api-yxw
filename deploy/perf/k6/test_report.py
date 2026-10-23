import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("perf_report", HERE / "report.py")
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)


def summary(*, reqs=10000, errors=0, checks=20000, checks_total=20000,
            complete=10000, waiting=600, duration=1900, admin_duration=None, data_rate=None):
    lines = [
        f"http_reqs................: {reqs} 500/s",
        f"http_req_failed..........: 0.00% {errors} out of {reqs}",
        f"http_req_waiting.........: avg=400ms min=300ms med=400ms p(90)=500ms p(95)={waiting}ms p(99)=900ms max=1s",
        f"http_req_duration........: avg=1.9s min=1s med=1.8s p(90)=1.9s p(95)={duration}ms p(99)=2s max=3s",
    ]
    if admin_duration is not None:
        lines.append(f"  {{ type:admin }}.......: avg=100ms med=100ms p(90)=200ms p(95)={admin_duration}ms p(99)=1s max=2s")
    if checks is not None:
        lines.append(f"checks...................: 100.00% {checks} out of {checks_total}")
    if complete is not None:
        lines.append(f"sse_complete.............: 100.00% {complete} out of {reqs}")
    if data_rate is not None:
        lines.append(f"data_received............: 1 MB {data_rate} MB/s")
    return "\n".join(lines) + "\n"


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=HERE)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.counter = 0

    def log(self, text=None, **meta):
        self.counter += 1
        fields = dict(
            target="perf-new-api-slave", base="http://10.0.0.1", mode="clusterip",
            vus="1200", dur="90s", replicas="1", cpu_peak_m="900", mem_peak_mi="200",
            job=f"stage-{self.counter}", ts="2026-10-23T08:00:00Z", images="gateway=v1;",
            load_config="sse-v1:k6-0.54:1-shard:mock-gpt", mock_config="300ms:30ms:50tokens",
            summary_schema="2", k6_exit_codes="0",
        )
        fields.update(meta)
        path = self.root / f"{self.counter}.log"
        path.write_text("===RUN_META===\n" + "\n".join(f"{k}={v}" for k, v in fields.items())
                        + "\n===END_META===\n" + (summary() if text is None else text))
        return path

    def run_record(self, text=None, **meta):
        return report.load_runs([str(self.log(text, **meta))])[0]

    def test_sse_verdict_and_strict_boundaries(self):
        cases = [
            ("healthy", summary(), "PASS"),
            ("latency boundary", summary(waiting=800), "FAIL"),
            ("error boundary", summary(errors=5, complete=9995), "FAIL"),
            ("truncated success", summary(complete=9995), "FAIL"),
            ("within error budget", summary(errors=4, complete=9996, checks=19996), "PASS"),
            ("missing complete counter", summary(complete=None), "INCOMPLETE"),
            ("old checks only", summary(complete=None, checks=19999), "INCOMPLETE"),
            ("missing integrity", summary(complete=None, checks=None), "INCOMPLETE"),
            ("empty run", summary(reqs=0, complete=0, checks=0, checks_total=0), "INCOMPLETE"),
            ("partial counts", summary(complete=None, checks_total=10000, checks=10000), "INCOMPLETE"),
        ]
        for name, text, expected in cases:
            with self.subTest(name=name):
                run = self.run_record(text)
                self.assertEqual(run.get("verdict"), expected)
                self.assertEqual(run["pass"], expected == "PASS")

    def test_each_shard_must_pass_and_have_all_metrics(self):
        healthy = summary(reqs=10000, complete=10000)
        unhealthy = summary(reqs=100, errors=1, complete=99, checks=199, checks_total=200)
        partial = "http_reqs................: 100 5/s\n"
        for text, expected in [(healthy + unhealthy, "FAIL"), (healthy + partial, "INCOMPLETE")]:
            with self.subTest(expected=expected):
                run = self.run_record(text, mode="clusterip-shard", shards="2", k6_exit_codes="0,0")
                self.assertEqual(run.get("verdict"), expected)
        run = self.run_record(healthy, mode="clusterip-shard", shards="2")
        self.assertEqual(run.get("verdict"), "INCOMPLETE")

    def test_checks_are_aggregated_from_counts_not_rounded_percent(self):
        parsed = report.parse_summary(summary(checks=19999) + summary(checks=20000))
        self.assertAlmostEqual(parsed["checks_pct"], 99.9975)

    def test_scene_specific_thresholds_and_unassessed_scenarios(self):
        cases = [
            ("burst", summary(waiting=1200), "PASS"),
            ("burst", summary(waiting=1500), "FAIL"),
            ("burst", summary(waiting=1200, errors=100, complete=9900), "FAIL"),
            ("admin", summary(waiting=1200, duration=2000, admin_duration=900, complete=None), "PASS"),
            ("admin", summary(waiting=100, duration=200, admin_duration=1000, complete=None), "FAIL"),
            ("admin", summary(admin_duration=900, errors=100, complete=None), "FAIL"),
            ("admin", summary(admin_duration=900, checks=19800, complete=None), "FAIL"),
            ("admin", summary(admin_duration=None, complete=None), "INCOMPLETE"),
            ("degrade", summary(), "UNASSESSED"),
            ("rolling", summary(), "UNASSESSED"),
            ("long", summary(), "UNASSESSED"),
            ("unknown", summary(), "UNASSESSED"),
        ]
        for mode, text, expected in cases:
            with self.subTest(mode=mode, expected=expected):
                run = self.run_record(text, mode=mode)
                self.assertEqual(run.get("verdict"), expected)

    def test_execution_failure_is_not_capacity_failure(self):
        for suffix in ("### remote_rc=1 cleaned=YES\n", "runner_rc=1\n"):
            run = self.run_record(summary() + suffix)
            self.assertEqual(run.get("verdict"), "INCOMPLETE")
            self.assertFalse(run["pass"])
        for codes, expected in [("0", "PASS"), ("99", "INCOMPLETE"), ("137", "INCOMPLETE"),
                                ("", "INCOMPLETE"), ("0,137", "INCOMPLETE")]:
            with self.subTest(codes=codes):
                run = self.run_record(summary(), summary_schema="2", k6_exit_codes=codes)
                self.assertEqual(run.get("verdict"), expected)
        run = self.run_record(summary(waiting=900), summary_schema="2", k6_exit_codes="99")
        self.assertEqual(run.get("verdict"), "FAIL")
        run = self.run_record(summary(complete=None), summary_schema="2", k6_exit_codes="0")
        self.assertEqual(run.get("verdict"), "INCOMPLETE")

    def test_invalid_metadata_and_missing_summary_are_not_silently_accepted(self):
        for meta in (dict(vus="bad"), dict(vus="0"), dict(replicas="0"), dict(replicas=""),
                     dict(replicas="2.5"), dict(cpu_peak_m="?")):
            with self.subTest(meta=meta):
                run = self.run_record(summary(), **meta)
                self.assertEqual(run.get("verdict"), "INCOMPLETE")
        run = self.run_record("")
        self.assertEqual(run.get("verdict"), "INCOMPLETE")

    def test_log_dir_discovers_nested_run_directories(self):
        nested = self.root / "reports" / "20261022-162242"
        nested.mkdir(parents=True)
        shutil.copyfile(self.log(job="nested-run"), nested / "nested-run.log")
        out = self.root / "nested.html"
        proc = subprocess.run([sys.executable, "-B", str(HERE / "report.py"),
                               "--log-dir", str(self.root / "reports"), "--out", str(out)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("[report] runs=1", proc.stdout)
        self.assertIn("nested-run", out.read_text())

    def test_missing_identity_metadata_and_invalid_duration_still_render(self):
        for field in ("job", "ts", "mode", "target", "base", "vus", "dur"):
            with self.subTest(field=field):
                path = self.log()
                path.write_text("\n".join(line for line in path.read_text().splitlines()
                                          if not line.startswith(field + "=")))
                runs = report.load_runs([str(path)])
                self.assertEqual(len(runs), 1)
                self.assertEqual(runs[0]["verdict"], "INCOMPLETE")
                report.render(runs, report.analyse(runs), str(self.root / "missing.html"))
                proc = subprocess.run([sys.executable, "-B", str(HERE / "report.py"), "--check", str(path)],
                                      capture_output=True, text=True)
                self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertEqual(self.run_record(dur="1..2s")["verdict"], "INCOMPLETE")
        self.assertEqual(self.run_record(dur="1m30s")["dur_s"], 90)

    def test_admin_rejects_dropped_iterations(self):
        text = summary(admin_duration=100, complete=None)
        for dropped, expected in [(0, "PASS"), (1, "FAIL"), (47900, "FAIL")]:
            with self.subTest(dropped=dropped):
                run = self.run_record(text + f"dropped_iterations.......: {dropped} 100/s\n", mode="admin")
                self.assertEqual(run["verdict"], expected)
                if dropped:
                    self.assertIn("dropped_iterations", run["failure_reasons"])

    def test_sse_tagged_p95_is_used_by_both_verdict_and_capacity(self):
        text = summary(waiting=400).replace("http_req_duration", "  { type:sse }........: p(95)=900ms\nhttp_req_duration", 1)
        run = self.run_record(text)
        self.assertEqual(run.get("verdict"), "FAIL")
        self.assertEqual(run["ttfb_p95"], 900)

    def test_report_displays_pending_states_and_does_not_invent_capacity(self):
        runs = [self.run_record(summary(), mode="long"),
                self.run_record(summary(checks=None, complete=None))]
        out = self.root / "pending.html"
        report.render(runs, report.analyse(runs), str(out))
        doc = out.read_text()
        self.assertIn("待评估", doc)
        self.assertIn("数据不完整", doc)
        self.assertIn("尚未验证", doc)
        self.assertNotIn("Replicas = ceil", doc)
        self.assertNotIn("单副本拐点（线性插值）", doc)
        self.assertNotIn("SLO：P95 首字 ≤", doc)

    def test_cli_distinguishes_slo_failure_from_unusable_data(self):
        cases = [(summary(), {}, 0), (summary(waiting=900), {}, 1),
                 (summary(complete=None, checks=None), {}, 2),
                 (summary(), {"mode": "long"}, 2), ("", {}, 2)]
        for text, meta, expected in cases:
            path = self.log(text, **meta)
            proc = subprocess.run([sys.executable, "-B", str(HERE / "report.py"), "--check", str(path)],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, expected, proc.stdout + proc.stderr)

    def test_runner_propagates_verdict_and_stops_on_incomplete_data(self):
        sandbox = self.root / "runner"
        k6 = sandbox / "deploy/perf/k6"
        k6.mkdir(parents=True)
        for name in ("run.sh", "report.py", "sse.js", "s3_burst.js", "s4_admin.js", "s9_long.js"):
            shutil.copyfile(HERE / name, k6 / name)
        shutil.copytree(HERE / "bodies", k6 / "bodies")
        remote = sandbox / "deploy/lib/ack_remote_jkt_dev.sh"
        remote.parent.mkdir(parents=True)
        remote.write_text('#!/bin/bash\nprintf "remote-call\\n" >> "$FIXTURE_CALLS"\ncat "$FIXTURE_LOG"\nexit "${FIXTURE_RC:-0}"\n')
        remote.chmod(0o700)
        bin_dir = sandbox / "bin"
        bin_dir.mkdir()
        sleep = bin_dir / "sleep"
        sleep.write_text("#!/bin/bash\nexit 0\n")
        sleep.chmod(0o700)
        env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"])
        calls = sandbox / "calls"
        env["FIXTURE_CALLS"] = str(calls)
        cases = [
            (["stage", "fixture", "1200", "90s"], summary(), 0, 0),
            (["stage", "fixture", "1200", "90s"], summary(waiting=900), 0, 1),
            (["stage", "fixture", "1200", "90s"], summary(complete=None), 0, 2),
            (["stage", "fixture", "1200", "90s"], summary(), 7, 2),
            (["ramp", "fixture", "1200", "600", "1800", "90s"], summary(waiting=900), 0, 1),
            (["ramp", "fixture", "1200", "600", "1800", "90s"], summary(complete=None), 0, 2),
            (["ladder", "fixture", "1200", "600", "1800", "90s", "1,2"], summary(complete=None), 0, 2),
        ]
        for args, text, remote_rc, expected in cases:
            with self.subTest(action=args[0], expected=expected, remote_rc=remote_rc):
                env["FIXTURE_LOG"] = str(self.log(text))
                env["FIXTURE_RC"] = str(remote_rc)
                calls.write_text("")
                proc = subprocess.run(["bash", str(k6 / "run.sh"), *args], env=env,
                                      capture_output=True, text=True, timeout=20)
                self.assertEqual(proc.returncode, expected, proc.stdout + proc.stderr)
                self.assertEqual(calls.read_text().count("remote-call"), 1)
                if expected == 2:
                    self.assertNotIn("容量高于", proc.stdout)
        checker = k6 / "report.py"
        checker.write_text("raise RuntimeError('fixture checker failure')\n")
        calls.write_text("")
        proc = subprocess.run(["bash", str(k6 / "run.sh"), "ramp", "fixture", "1200", "600", "1800", "90s"],
                              env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertEqual(calls.read_text().count("remote-call"), 1)
        self.assertNotIn("未通过 SLO", proc.stdout)

    def test_no_passing_sse_never_displays_a_failed_or_admin_run_as_best(self):
        for run in (self.run_record(summary(waiting=2820), vus="3000"),
                    self.run_record(summary(admin_duration=900, complete=None), mode="admin")):
            with self.subTest(mode=run["mode"]):
                analysis = report.analyse([run])
                self.assertIsNone(analysis.get("best"))
                out = self.root / "report.html"
                report.render([run], analysis, str(out))
                card = out.read_text().split("SSE 最优通过档", 1)[1].split('<div class="card">', 1)[0]
                self.assertIn("无通过档", card)
                self.assertNotIn("500.0", card)

    def test_bandwidth_uses_decimal_units_and_only_public_path(self):
        self.assertAlmostEqual(report.parse_summary("data_received..................: 1 MB 1 MB/s\n")["data_mbps"], 8.0)
        cluster = self.run_record(summary(data_rate=10), mode="clusterip")
        public = self.run_record(summary(data_rate=5), mode="public-url")
        analysis = report.analyse([cluster, public], 100)
        self.assertAlmostEqual(analysis["bw_util"], 0.4)
        self.assertAlmostEqual(analysis["internal_bw_peak"], 80.0)
        self.assertNotIn("bw_util", cluster)
        internal_only = report.analyse([cluster], 100)
        self.assertNotIn("bw_util", internal_only)
        self.assertIn("未计算 EIP 利用率", internal_only.get("bw_note", ""))

    def test_stage_chart_does_not_sum_different_percentiles(self):
        run = self.run_record(summary(), mock_config="first_token_delay_ms=300,token_interval_ms=30,tokens_per_response=50")
        rendered = report.svg_stages(run)
        self.assertIn("不可相加", rendered)
        self.assertIn("mock 首字（配置）", rendered)
        legacy = self.run_record(summary(), mock_config="300ms:30ms:50tokens")
        legacy_rendered = report.svg_stages(legacy)
        self.assertIn("不给出 mock 首字/吐字参考", legacy_rendered)
        self.assertNotIn("合计", legacy_rendered)
        out = self.root / "stages.html"
        report.render([run], report.analyse([run]), str(out))
        doc = out.read_text()
        self.assertIn("阶段耗时参考", doc)
        self.assertIn("不可相加", doc)

    def test_structured_archive_records_sampling_and_config_snapshot(self):
        log = self.log(summary(), cpu_max_pod_m="500", pods_peak="2", sample_rows="6",
                       load_config="k6-0.54.0:sse.js@abc123:const-vus:model=mock-gpt",
                       mock_config="first_token_delay_ms=300,token_interval_ms=30")
        archived = self.root / "run.json"
        proc = subprocess.run([sys.executable, "-B", str(HERE / "report.py"),
                               "--logs", str(log), "--json", str(archived)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        run = json.loads(archived.read_text())["runs"][0]
        self.assertEqual(run["verdict"], "PASS")
        self.assertEqual(run["pods_peak"], "2")
        self.assertEqual(run["sample_rows"], "6")
        self.assertEqual(run["cpu_max_pod_m"], "500")
        self.assertIn("sse.js@abc123", run["load_config"])
        self.assertIn("first_token_delay_ms=300", run["mock_config"])
        self.assertFalse((self.root / "run.html").exists())

    def test_run_archives_samples_separately_and_keeps_log_parseable(self):
        sandbox = self.root / "archive_run"
        k6 = sandbox / "deploy/perf/k6"
        k6.mkdir(parents=True)
        for name in ("run.sh", "report.py", "sse.js"):
            shutil.copyfile(HERE / name, k6 / name)
        shutil.copytree(HERE / "bodies", k6 / "bodies")
        remote = sandbox / "deploy/lib/ack_remote_jkt_dev.sh"
        remote.parent.mkdir(parents=True)
        remote.write_text('#!/bin/bash\ncat "$FIXTURE_LOG"\nexit 0\n')
        remote.chmod(0o700)
        fixture = self.log(summary())
        fixture.write_text(fixture.read_text()
                           + "===SAMPLES===\n10:00:00\tpod-a\t300m\t128Mi\n10:00:05\tpod-b\t500m\t256Mi\n")
        env = dict(os.environ, FIXTURE_LOG=str(fixture))
        proc = subprocess.run(["bash", str(k6 / "run.sh"), "stage", "perf-new-api-slave", "100", "5s"],
                              env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        run_dir = Path(proc.stdout.split("本次输出目录：")[1].splitlines()[0].strip())
        log = next(run_dir.glob("*.log"))
        samples = next(run_dir.glob("*.samples.tsv"))
        archived = next(run_dir.glob("*.json"))
        self.assertNotIn("pod-a", log.read_text())
        self.assertIn("pod-b", samples.read_text())
        self.assertEqual(json.loads(archived.read_text())["runs"][0]["verdict"], "PASS")

    def test_capacity_interpolates_only_inside_a_comparable_latency_bracket(self):
        passing = self.run_record(summary(waiting=600), vus="1200")
        failing = self.run_record(summary(waiting=1000).replace("500/s", "600/s"), vus="1800")
        analysis = report.analyse([passing, failing])
        groups = analysis.get("capacity_groups", [])
        self.assertEqual(len(groups), 1)
        self.assertAlmostEqual(groups[0]["knee_vus"], 1500)
        self.assertAlmostEqual(groups[0]["knee_rps"], 550)
        self.assertFalse(groups[0]["target_verified"])
        self.assertNotIn("replicas_for_target", analysis)

    def test_capacity_separates_topology_and_configuration(self):
        variants = [dict(replicas="2"), dict(mode="clusterip-dual", replicas="2"),
                    dict(target="other"), dict(base="http://10.0.0.2"), dict(images="gateway=v2;"),
                    dict(dur="120s"), dict(load_config="other-load"), dict(mock_config="other-mock")]
        for variant in variants:
            with self.subTest(variant=variant):
                passing = self.run_record(summary(waiting=600), vus="1200")
                failing = self.run_record(summary(waiting=1000), vus="1800", **variant)
                groups = report.analyse([passing, failing]).get("capacity_groups", [])
                self.assertEqual(len(groups), 2)
                self.assertTrue(all(g["knee_vus"] is None for g in groups))

    def test_missing_configuration_never_becomes_an_implicit_shared_profile(self):
        for field in ("images", "load_config", "mock_config", "dur"):
            with self.subTest(field=field):
                runs = [self.run_record(summary(waiting=600), vus="1200", **{field: ""}),
                        self.run_record(summary(waiting=1000), vus="1800", **{field: ""})]
                groups = report.analyse(runs).get("capacity_groups", [])
                self.assertTrue(groups)
                self.assertTrue(all(g["knee_vus"] is None for g in groups))
                self.assertTrue(all(not g["config_complete"] for g in groups))
        for bad in ("unavailable", "mixed", "changed"):
            with self.subTest(mock_config=bad):
                runs = [self.run_record(summary(waiting=600), vus="1200", mock_config=bad),
                        self.run_record(summary(waiting=1000), vus="1800", mock_config=bad)]
                groups = report.analyse(runs).get("capacity_groups", [])
                self.assertTrue(all(g["knee_vus"] is None for g in groups))
                self.assertTrue(all(not g["config_complete"] for g in groups))

    def test_no_extrapolation_or_interpolation_across_non_latency_failures(self):
        cases = [
            [self.run_record(summary(waiting=400), vus="600"), self.run_record(summary(waiting=600), vus="1200")],
            [self.run_record(summary(waiting=600), vus="1200"), self.run_record(summary(waiting=700, errors=10), vus="1800")],
            [self.run_record(summary(waiting=600), vus="1200"), self.run_record(summary(waiting=1000, complete=9900), vus="1800")],
            [self.run_record(summary(waiting=900), vus="600"), self.run_record(summary(waiting=600), vus="1200")],
            [self.run_record(summary(waiting=600), vus="1200"), self.run_record(summary(waiting=1000), vus="1200")],
            [self.run_record(summary(waiting=600), vus="1200"), self.run_record(summary(checks=None, complete=None), vus="1500"),
             self.run_record(summary(waiting=1000), vus="1800")],
        ]
        for runs in cases:
            with self.subTest(vus=[r["vus_i"] for r in runs]):
                groups = report.analyse(runs).get("capacity_groups", [])
                self.assertTrue(groups)
                self.assertTrue(all(g["knee_vus"] is None for g in groups))

    def test_target_is_verified_only_by_an_actual_passing_steady_run(self):
        for mode, expected in [("clusterip", True), ("clusterip-dual", True),
                               ("public-url", False), ("burst", False), ("long", False)]:
            runs = [self.run_record(summary(), vus="1500", mode=mode)]
            analysis = report.analyse(runs)
            self.assertEqual(bool(analysis.get("verified_replicas")), expected)

    def test_legacy_logs_cannot_prove_integrity_or_capacity(self):
        for mode in ("clusterip", "admin"):
            run = self.run_record(summary(complete=None, admin_duration=900), mode=mode,
                                  summary_schema="", k6_exit_codes="")
            self.assertEqual(run["verdict"], "INCOMPLETE")
        run = self.run_record(summary(complete=None, waiting=2820), summary_schema="", k6_exit_codes="")
        self.assertEqual(run["verdict"], "FAIL")
        self.assertFalse(run["evidence_complete"])
        passing = self.run_record(summary(), vus="600")
        self.assertIsNone(report.analyse([passing, run])["capacity_groups"][0]["knee_vus"])

    def test_shards_without_overlap_evidence_cannot_verify_total_concurrency(self):
        run = self.run_record(summary() + summary(), mode="clusterip-shard", vus="1500", shards="2",
                              k6_exit_codes="0,0")
        self.assertEqual(run["verdict"], "UNASSESSED")
        self.assertFalse(report.analyse([run])["verified_replicas"])
        self.assertIsNone(report.analyse([run])["capacity_groups"][0]["knee_vus"])

    @unittest.skipUnless(shutil.which("node"), "Node.js is required for the k6 script boundary tests")
    def test_admin_http_200_business_failure_is_not_success(self):
        harness = r'''
const fs = require('node:fs');
const vm = require('node:vm');
(async () => {
  let response;
  const checks = [];
  const context = vm.createContext({ __ENV: { BASE: 'http://example.test' } });
  const modules = {
    'k6/http': new vm.SyntheticModule(['default'], function() { this.setExport('default', { get() { return response; } }); }, { context }),
    'k6': new vm.SyntheticModule(['check'], function() { this.setExport('check', (r, predicates) => {
      const result = Object.values(predicates).every(fn => fn(r)); checks.push(result); return result;
    }); }, { context }),
  };
  const mod = new vm.SourceTextModule(fs.readFileSync(process.argv[1], 'utf8'), { context });
  await mod.link(name => modules[name]);
  await mod.evaluate();
  for (response of [
    { status: 200, json: () => ({ success: true, data: { items: [] } }) },
    { status: 200, json: () => ({ success: false, message: 'query failed' }) },
    { status: 200, json: () => { throw new Error('invalid json'); } },
    { status: 200, json: () => null },
    { status: 403, json: () => ({ success: true }) },
  ]) mod.namespace.default({ token: 'fixture' });
  console.log(JSON.stringify(checks));
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
        proc = subprocess.run(["node", "--experimental-vm-modules", "--no-warnings", "-e", harness, str(HERE / "s4_admin.js")],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), [True, False, False, False, False])

    @unittest.skipUnless(shutil.which("node"), "Node.js is required for the k6 script boundary tests")
    def test_k6_scripts_count_only_real_complete_sse_events(self):
        harness = r'''
const fs = require('node:fs');
const vm = require('node:vm');
const path = process.argv[1];
const responses = [
  { status: 200, body: 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n' },
  { status: 200, body: 'data: {"delta":"[DONE]"}\n\n' },
  { status: 200, body: 'data: {"delta":"ok"}\n\n' },
  { status: 500, body: 'data: [DONE]\n\n' },
  { status: 200, body: 'data:{"choices":[{"index":0,"finish_reason":"length"}]}\r\n\r\ndata:[DONE]\r\n\r\n' },
  { status: 200, body: 'data: {"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}\n\ndata: [DONE]\n\n' },
  { status: 200, body: 'data: {"error":{"message":"upstream failed"}}\n\ndata: [DONE]\n\n' },
  { status: 200, body: 'data: {"choices":[{"index":0,"finish_reason":"stop"}]}\n\ndata: {"error":"failed"}\n\ndata: [DONE]\n\n' },
  { status: 200, body: 'data: {"choices":[{"index":0,"finish_reason":"stop"}]}\n\ndata: [DONE]' },
  { status: 200, body: 'data: [DONE]\n\ndata: {"choices":[{"index":0,"finish_reason":"stop"}]}\n\n' },
];
(async () => {
  const values = {};
  let response;
  const context = vm.createContext({ __ENV: { BASE: 'http://example.test', TOKEN: 'fixture' } });
  const modules = {
    'k6/http': new vm.SyntheticModule(['default'], function() { this.setExport('default', { post() { return response; } }); }, { context }),
    'k6': new vm.SyntheticModule(['check'], function() { this.setExport('check', (r, checks) => Object.values(checks).every(fn => fn(r))); }, { context }),
    'k6/metrics': new vm.SyntheticModule(['Rate'], function() { this.setExport('Rate', class {
      constructor(name) { this.name = name; values[name] = []; }
      add(value) { values[this.name].push(Boolean(value)); }
    }); }, { context }),
  };
  const mod = new vm.SourceTextModule(fs.readFileSync(path, 'utf8'), { context });
  await mod.link(name => modules[name]);
  await mod.evaluate();
  for (response of responses) mod.namespace.default();
  console.log(JSON.stringify({ values, thresholds: mod.namespace.options.thresholds }));
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
        for filename in ("sse.js", "s3_burst.js"):
            with self.subTest(filename=filename):
                proc = subprocess.run(["node", "--experimental-vm-modules", "--no-warnings", "-e", harness, str(HERE / filename)],
                                      capture_output=True, text=True)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                data = json.loads(proc.stdout)
                self.assertEqual(data["values"].get("sse_complete"), [True, False, False, False, True, False, False, False, False, False])
                threshold = data["thresholds"].get("sse_complete", [])
                self.assertTrue(threshold, "incomplete streams must affect the k6 exit verdict")


if __name__ == "__main__":
    unittest.main()
