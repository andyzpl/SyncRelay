"""Phase B-2 contracts: 运营首页 → 分组列表 → 执行详情.

These are source and cross-source contracts plus the local mirrors that run
without Apple tooling. tests/run_projection_test.m on macOS CI covers only the
pure Foundation projection (phases, counts, time text, row and gate tables); it
does not cover UIKit layout, touch handling or page navigation, and nothing in
this file is a device result.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def project_source() -> str:
    return (ROOT / "Core/SRRunProjection.m").read_text(encoding="utf-8")


def screens_source() -> str:
    return (ROOT / "UI/SRPlanScreens.m").read_text(encoding="utf-8")


def home_block() -> str:
    source = screens_source()
    return source.split("@implementation SROperationsHomeScreen", 1)[1].split("@end", 1)[0]


def group_list_block() -> str:
    source = screens_source()
    return source.split("@implementation SRGroupListScreen", 1)[1].split("@end", 1)[0]


def detail_block() -> str:
    source = screens_source()
    return source.split("@implementation SRRunDetailScreen", 1)[1].split("@end", 1)[0]


def detail_interface() -> str:
    source = screens_source()
    return source.split("@interface SRRunDetailScreen", 1)[1].split("@end", 1)[0]


def project_impl() -> str:
    return project_source().split("@implementation SRRunProjection", 1)[1]


def record_screen_block() -> str:
    """The older record/plan screens, which must no longer own a command."""
    source = screens_source()
    return source.split("@implementation SRRecordScreen", 1)[1].split("@end", 1)[0]


def new_pages() -> str:
    """The three B-2 pages only; the older record screens are excluded so their
    pre-existing explicit confirm route is not mistaken for an automatic one."""
    return home_block() + group_list_block() + detail_block()


def evaluate_stale_binding(bound_run_id, current_run_id):
    """Execute the decision table of SRRunProjection.pageIsStaleForBoundRun:.

    The authoritative executable test is the same five shapes in
    tests/run_projection_test.m (macOS CI). This mirror runs locally so the
    table itself is exercised here as well, and the assertions below pin it to
    the source conditions it is transcribed from.
    """
    bound = bound_run_id or None
    current = current_run_id or None
    if not bound:
        return current is not None
    return not (current is not None and current == bound)


def card_allows_start(card):
    """Execute the start gate of SRRunDetailScreen.startConfirmedRule:.

    A frozen card is only startable while it exists, still has no run, stays
    inside the 20-group range, is unlocked and the account is not occupied. The
    card that appears during a confirmation is exactly the case this guards.
    """
    if not isinstance(card, dict):
        return False
    if isinstance(card.get("latestRun"), dict):
        return False
    if card.get("targetCount", 0) > 20:
        return False
    if card.get("initialUnlocked") is not True:
        return False
    if card.get("accountOccupied") is True:
        return False
    return True


def group_configuration_rows(configuration):
    """Execute the row projection of SRRunProjection.groupRowsForConfiguration:.

    Only the fields the group list draws are mirrored: the identifier, the group
    name and the target count. The point of the A/B case is which configuration
    is projected, so the mirror must be fed exactly one of them.
    """
    rules = configuration.get("rules") if isinstance(configuration, dict) else None
    if not isinstance(rules, list):
        return []
    rows = []
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        targets = rule.get("targets") if isinstance(rule.get("targets"), list) else []
        rows.append({
            "identifier": rule.get("id") or "",
            "name": rule.get("name") or "未命名分组",
            "targetCount": len([t for t in targets if isinstance(t, dict)]),
        })
    return rows


def select_group_configuration(frozen, saved):
    """Execute the group list's configuration choice.

    The configuration frozen with the displayed content always wins; the saved
    settings are read only when the page was opened with no content at all. A
    saved settings row must never be substituted for a frozen one.
    """
    return frozen if frozen is not None else saved


def live_action_allows(bound_run_id, mounted_run_id, account_ok, session_owned):
    """Execute the gate of SROperationsHomeScreen.performLiveAction:runID:.

    A pause/continue is allowed only while the account verifies, the tapped row
    carried a run, the session still belongs to this account and the mounted run
    is exactly the bound one. Anything else stops before the command.
    """
    if not account_ok:
        return False
    if not bound_run_id:
        return False
    if not session_owned:
        return False
    if not mounted_run_id or mounted_run_id != bound_run_id:
        return False
    return True


def read_only_viewer_body(row):
    """Mirror of SRGroupListScreen.showReadOnlyGroup:, the text it composes.

    The viewer draws only the name, targets and target names of the row it was
    given; this reproduction makes the A/B case executable locally.
    """
    name = row.get("name") or "未命名分组"
    targets = row.get("targets") if isinstance(row.get("targets"), list) else []
    names = row.get("targetNames") if isinstance(row.get("targetNames"), list) else []
    lines = []
    for index, identifier in enumerate(targets):
        label = names[index] if index < len(names) else None
        lines.append(f"{index + 1}. {label}（{identifier}）" if label else f"{index + 1}. {identifier}")
    return "\n".join([name] + lines)


class PhaseB2UI(unittest.TestCase):
    # --- 运营首页 ---

    def test_home_keeps_the_four_fixed_sections_in_order(self):
        home = home_block()
        self.assertIn('@[@"运行状态", @"当前内容", @"分组概览", @"最近一次结果"]', home)
        # Four sections plus the single-section error shapes.
        self.assertIn("(self.accountInvalid || self.problem) ? 1 : 4", home)

    def test_home_separates_account_failure_read_failure_no_content_and_no_groups(self):
        home = home_block()
        # Account changed is its own state, not "已完成" and not "暂无内容".
        self.assertIn('@"账号无法核对或已经改变"', home)
        self.assertIn("self.accountInvalid = ![self verified]", home)
        # Read failure is a distinct, retryable state.
        self.assertIn('@"状态读取失败"', home)
        self.assertIn('@"内容读取失败"', home)
        # No content and no groups are separate texts.
        self.assertIn('@"尚未捕获内容"', home)
        self.assertIn('@"分组概览 · 尚未建立分组"', home)
        for phrase in ("账号无法核对或已经改变", "读取已停止", "尚未捕获内容", "尚未建立分组"):
            self.assertIn(phrase, home)

    def test_home_resolves_the_current_content_from_frozen_sources(self):
        resolve = home_block().split("- (BOOL)resolveContent:", 1)[1].split("\n}", 1)[0]
        # In-memory preview first, but only for this account.
        self.assertIn("self.capture.preview", resolve)
        self.assertIn('self.capture.status[@"account"]', resolve)
        # Then prepared operations content, then the newest confirmed plan.
        self.assertIn("operationsContentForAccount", home_block())
        self.assertIn("self.operations[@\"current\"]", resolve)
        self.assertIn("plansForAccount:self.account limit:1 offset:0", resolve)
        self.assertIn("[self.store plan:newest account:self.account", resolve)
        # A preview is never promoted to confirmed content.
        self.assertIn("SRHomeModePreview", resolve)
        # The only confirm route stays the existing explicit one in the preview
        # screen, and none of the three new pages calls it on open.
        self.assertEqual(screens_source().count("confirmForCurrentAccount"), 1)
        self.assertNotIn("confirmForCurrentAccount", new_pages())

    def test_home_shows_the_existing_source_time_fields_without_converting_the_host_value(self):
        home = home_block()
        for expression in ("localDateTimeText:", "observedTimeTextForEnvelope:",
                           "frozenTimeTextForEnvelope:", "hostTimeTextForEnvelope:"):
            self.assertIn(expression, home)
        self.assertIn('@"宿主来源时间（未验证）"', home)
        self.assertIn('@"插件来源时间"', home)
        # No page clock is used as a substitute for a missing time.
        self.assertNotIn("[NSDate date]", screens_source())

    def test_home_group_entry_targets_the_content_plan_not_the_history_list(self):
        home = home_block()
        entry = home.split("if (path.section == 2)", 1)[1].split("\n    if (path.section == 3", 1)[0]
        # The primary group entry carries this content's plan.
        self.assertIn("SRCreateGroupList(self.store, self.execution, self.account", entry)
        self.assertIn("self.verifyAccount, self.planID", entry)
        # The full plan list is a separate, explicitly labelled row.
        self.assertIn('@"全部内容计划"', home)
        self.assertIn("SRCreatePlanList(self.store, self.account", entry)
        self.assertLess(entry.index("path.row == 1"), entry.index("SRCreateGroupList"))

    def test_home_recent_result_points_at_that_exact_run(self):
        home = home_block()
        recent = home.split("- (void)resolveRecentResult", 1)[1].split("\n}", 1)[0]
        # The archived content's own plan is preferred over the current one.
        self.assertIn('self.operations[@"recent"]', recent)
        self.assertIn("ruleCardsForPlan:plan account:self.account", recent)
        self.assertIn("latestRunInCards:", recent)
        # The route carries the run identity, not "the current task".
        route = home.split("if (path.section == 3 && self.recentRun)", 1)[1].split("\n    }", 1)[0]
        self.assertIn("self.recentRunPlanID", route)
        self.assertIn('self.recentRun[@"rule_id"]', route)
        self.assertIn('self.recentRun[@"id"]', route)

    def test_home_group_overview_reports_real_counts_and_progress(self):
        home = home_block()
        self.assertIn("overviewForGroupRows:", home)
        self.assertIn('@"%@ 个分组 · %@ 个目标群\\n已处理 %@/%@ · %@ 个分组未开始"', home)

    def test_home_settings_round_trip_is_preserved_as_a_top_bar_route(self):
        home = home_block()
        # 12.2 fixes the top bar as 关闭 / SyncRelay 运营 / 设置.
        self.assertIn('initWithTitle:@"关闭"', home)
        self.assertIn('initWithTitle:@"设置"', home)
        self.assertIn("action:@selector(settingsPressed)", home)
        self.assertIn("if (self.openSettings) self.openSettings();", home)
        self.assertIn("- (void)settingsPressed {", home)

    def test_home_offers_live_progress_and_controls_only_for_this_account(self):
        home = home_block()
        self.assertIn("progressBelongsToCurrentAccount", home)
        self.assertIn("self.execution.currentRunID", home)
        self.assertIn("[self.execution pauseForAccount:self.account error:&error]", home)
        self.assertIn("[self.execution resumeRun:bound account:self.account error:&error]", home)
        # Continuing while an attempt is still in flight is refused before the call.
        self.assertIn('[counts[@"submitting"] unsignedIntegerValue] > 0', home)

    def test_home_live_commands_use_the_run_saved_with_the_tapped_row(self):
        """Pause/continue must target the batch the row was drawn for.

        Reading currentRunID again inside the handler lets a newer batch receive
        a command the user aimed at an older one.
        """
        home = home_block()
        route = home.split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1)[1]
        self.assertIn('[self performLiveAction:action[@"kind"] runID:action[@"runID"]]', route)
        self.assertNotIn('performLiveAction:action[@"kind"]]', route)
        # The action rows carry the identity they were built with.
        actions = home.split("- (void)buildRunActions {", 1)[1].split("\n}", 1)[0]
        self.assertIn('@"kind": @"pause", @"title": @"暂停", @"runID": run', actions)
        self.assertIn('@"kind": @"resume", @"title": @"继续未发", @"runID": run', actions)

        handler = home.split("- (void)performLiveAction:(NSString *)kind runID:(NSString *)bound {", 1)[1]
        handler = handler.split("\n}", 1)[0]
        # Bound id, account and session are checked before the mounted run, and
        # the mounted run before any command call.
        self.assertLess(handler.index("[bound isKindOfClass:NSString.class]"),
                        handler.index("progressBelongsToCurrentAccount"))
        self.assertLess(handler.index("progressBelongsToCurrentAccount"),
                        handler.index("NSString *mounted = self.execution.currentRunID;"))
        self.assertLess(handler.index("[mounted isEqual:bound]"), handler.index("pauseForAccount:"))
        self.assertLess(handler.index("[mounted isEqual:bound]"), handler.index("resumeRun:"))
        # Continuing resumes the bound batch, never a freshly read one.
        self.assertIn("[self.execution resumeRun:bound account:self.account error:&error]", handler)
        self.assertNotIn("resumeRun:run ", handler)
        self.assertNotIn("resumeRun:mounted", handler)
        # Every missing/changed/expired identity only alerts and refreshes.
        refusals = handler.split("NSError *error = nil;", 1)[0]
        self.assertNotIn("pauseForAccount:", refusals)
        self.assertNotIn("resumeRun:", refusals)
        self.assertEqual(refusals.count("[self reload]; return;"), 4)

        # Same batch is allowed; A→B, a vanished batch and a missing id are not.
        self.assertTrue(live_action_allows("run-a", "run-a", True, True))
        self.assertFalse(live_action_allows("run-a", "run-b", True, True))
        self.assertFalse(live_action_allows("run-a", None, True, True))
        self.assertFalse(live_action_allows("run-a", "", True, True))
        self.assertFalse(live_action_allows(None, "run-a", True, True))
        self.assertFalse(live_action_allows("", "run-a", True, True))
        self.assertFalse(live_action_allows("run-a", "run-a", False, True))
        self.assertFalse(live_action_allows("run-a", "run-a", True, False))

    # --- 分组列表 ---

    def test_group_list_builds_rows_from_the_frozen_plan(self):
        listing = group_list_block()
        self.assertIn("ruleCardsForPlan:self.planID account:self.account", listing)
        self.assertIn("groupRowsForCards:", listing)
        # No confirmed plan -> read-only configuration view.
        self.assertIn("groupRowsForConfiguration:", listing)
        self.assertIn("self.readOnly = YES", listing)

    def test_group_list_shows_name_targets_progress_status_and_detail_route(self):
        listing = group_list_block()
        self.assertIn('cell.textLabel.text = row[@"name"]', listing)
        self.assertIn('row[@"targetCount"]', listing)
        self.assertIn('row[@"progressText"]', listing)
        self.assertIn('row[@"statusText"]', listing)
        self.assertIn('row[@"blockedText"]', listing)
        route = listing.split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1)[1]
        self.assertIn("SRCreateRunDetail(self.store, self.execution, self.account", route)
        self.assertIn('row[@"identifier"]', route)

    def test_group_list_search_and_filter_are_read_only(self):
        listing = group_list_block()
        self.assertIn("UISearchResultsUpdating", screens_source())
        self.assertIn("self.search.searchResultsUpdater = self", listing)
        self.assertIn('搜索分组或群', screens_source())
        apply = listing.split("- (void)applyFilter {", 1)[1].split("\n}", 1)[0]
        self.assertIn("[SRRunProjection rows:self.allRows matchingText:", apply)
        self.assertIn("filter:self.filter", apply)
        # The filter menu only assigns the filter and re-projects.
        menu = listing.split("- (void)chooseFilter {", 1)[1].split("\n}", 1)[0]
        self.assertIn("weakSelf.filter = identifier; [weakSelf applyFilter]", menu)
        for forbidden in ("saveConfiguration", "startRule:", "resumeRun:", "cancelRun:", "archive"):
            self.assertNotIn(forbidden, listing)

    def test_group_list_keeps_the_twenty_group_limit_visible(self):
        self.assertIn("SRRunProjectionTargetLimit", project_source())
        self.assertIn("超过每条 %lu 群的执行范围", project_source())
        self.assertIn("不会截取前 %lu 群", project_source())
        # The store still refuses >20 targets; the page only displays it.
        store = (ROOT / "Core/SRStore.m").read_text(encoding="utf-8")
        self.assertIn("targets.count > 0 && targets.count <= 20", store)
        self.assertIn("SRRunProjectionTargetLimit = 20", project_source())

    # --- 执行详情 ---

    def test_detail_binds_account_plan_rule_and_run(self):
        header = (ROOT / "UI/SRPlanScreens.h").read_text(encoding="utf-8")
        self.assertIn("SRCreateRunDetail", header)
        declaration = header.split("SRCreateRunDetail", 1)[1].split(");", 1)[0]
        for part in ("account", "planID", "ruleID", "runID"):
            self.assertIn(part, declaration)
        detail = detail_block()
        interface = detail_interface()
        self.assertIn("@property(nonatomic, copy, nullable) NSString *planID;", interface)
        self.assertIn("@property(nonatomic, copy, nullable) NSString *ruleID;", interface)
        self.assertIn("@property(nonatomic, copy, nullable) NSString *runID;", interface)
        # No vague "current task" lookup is used to resolve the run.
        for forbidden in ("currentTask", "currentRunForAccount", "latestRunForAccount"):
            self.assertNotIn(forbidden, screens_source())

    def test_detail_shows_raw_state_actual_counts_and_persisted_times(self):
        detail = detail_block()
        self.assertIn('@"原始状态（持久化值）"', detail)
        self.assertIn("countLinesForSummary:", detail)
        self.assertIn('@"开始时间"', detail)
        self.assertIn('@"结束时间"', detail)
        self.assertIn('self.summary[@"startedText"]', detail)
        self.assertIn('self.summary[@"endedText"]', detail)
        self.assertIn('@"处理完成不等于全部送达', detail)
        # Cancelling is never presented as completion.
        self.assertIn('@"已取消"', project_source())

    def test_detail_revalidates_identity_before_every_command(self):
        detail = detail_block()
        revalidate = detail.split("- (BOOL)revalidateRun:(NSString *)runID {", 1)[1].split("\n}", 1)[0]
        self.assertIn("[self verified]", revalidate)
        self.assertIn("self.replaced", revalidate)
        self.assertIn("ruleCardsForPlan:self.planID account:self.account", revalidate)
        self.assertIn('[run[@"id"] isEqual:runID]', revalidate)
        # Every command path goes through it.
        for command in ("pausePressed:", "resumePressed:", "cancelPressed:", "endPressed:"):
            body = detail.split("- (void)" + command, 1)[1].split("\n- (void)", 1)[0]
            self.assertIn("[self revalidateRun:runID]", body, command)
        # Start re-reads the frozen card and the frozen preview instead.
        start = detail.split("- (void)startPressed {", 1)[1].split("\n}", 1)[0]
        self.assertIn("ruleCardsForPlan:self.planID account:account", start)
        self.assertIn("smallGroupRulePreview:rule account:account", start)
        confirmed = detail.split("- (void)startConfirmedRule:", 1)[1].split("\n}", 1)[0]
        self.assertIn("[account isEqual:self.account]", confirmed)
        self.assertIn("smallGroupRulePreview:rule account:account", confirmed)
        # The checks run in a safe order: account first, then the replaced-run
        # marker, and only then the durable read that decides the run identity.
        self.assertLess(revalidate.index("[self verified]"), revalidate.index("self.replaced"))
        self.assertLess(revalidate.index("self.replaced"), revalidate.index("ruleCardsForPlan"))
        # A late confirmation re-checks the account before it re-checks the run.
        self.assertLess(confirmed.index("[account isEqual:self.account]"),
                        confirmed.index("smallGroupRulePreview"))
        cancel_confirmed = detail.split("- (void)cancelConfirmedRun:", 1)[1].split("\n}", 1)[0]
        self.assertLess(cancel_confirmed.index("[account isEqual:self.account]"),
                        cancel_confirmed.index("[self revalidateRun:runID]"))

    def test_repeated_confirmation_cannot_reach_a_second_command_site(self):
        detail = detail_block()
        # Exactly one call site per command, so a duplicate confirm can only
        # repeat the same guarded call, never create a parallel batch.
        for command in ("startRule:rule account:account", "cancelRun:runID account:account",
                        "endRun:runID account:account"):
            self.assertEqual(detail.count(command), 1, command)
        # The start command is reachable only from the single confirm handler.
        self.assertEqual(detail.count("[weakSelf startConfirmedRule:rule account:account]"), 1)
        self.assertEqual(detail.count("[weakSelf cancelConfirmedRun:runID account:account]"), 1)

    def test_detail_uses_the_existing_session_commands(self):
        detail = detail_block()
        self.assertIn("[self.execution startRule:rule account:account error:&error]", detail)
        self.assertIn("[self.execution pauseForAccount:self.account error:&error]", detail)
        self.assertIn("[self.execution resumeRun:runID account:self.account error:&error]", detail)
        self.assertIn("[self.execution cancelRun:runID account:account error:&error]", detail)
        self.assertIn("endRun:runID account:account error:&error", detail)
        # Pause never runs through a run the session does not own.
        pause = detail.split("- (void)pausePressed:(NSString *)runID {", 1)[1].split("\n}", 1)[0]
        self.assertIn("self.execution.currentRunID isEqual:runID", pause)

    def test_cancel_has_one_confirmation_and_explains_in_flight(self):
        detail = detail_block()
        cancel = detail.split("- (void)cancelPressed:(NSString *)runID {", 1)[1].split("\n}", 1)[0]
        self.assertIn("取消本组剩余发送？", cancel)
        self.assertIn("已提交的消息无法撤回", cancel)
        self.assertIn("在途消息仍可能发送完成", cancel)
        self.assertIn("其他分组不会自动开始", cancel)
        self.assertEqual(cancel.count("UIAlertController alertControllerWithTitle"), 1)
        # The confirmed command re-checks the account it captured.
        confirmed = detail.split("- (void)cancelConfirmedRun:", 1)[1].split("\n}", 1)[0]
        self.assertIn("[account isEqual:self.account]", confirmed)
        self.assertIn("[self revalidateRun:runID]", confirmed)

    def test_detail_offers_the_exceptions_entry_for_the_same_run(self):
        header = (ROOT / "UI/SRPlanScreens.h").read_text(encoding="utf-8")
        self.assertIn("SRCreateRunExceptions", header)
        detail = detail_block()
        self.assertIn('@"查看异常与未发项"', detail)
        self.assertIn("SRCreateRunExceptions(self.store, self.account", detail)
        # It reuses the existing paged screen instead of a second implementation.
        source = screens_source()
        factory = source.split("UIViewController *SRCreateRunExceptions", 1)[1]
        self.assertIn("screen.kind = SRRecordExceptions", factory)

    def test_no_page_writes_sql_or_mutates_frozen_state(self):
        source = screens_source()
        for forbidden in ("sqlite3", "INSERT INTO", "UPDATE ", "DELETE FROM", "DROP TABLE"):
            self.assertNotIn(forbidden, source)
        projection = project_source()
        for forbidden in ("sqlite3", "INSERT INTO", "UPDATE ", "UIKit", "UIView"):
            self.assertNotIn(forbidden, projection)
        # The projection module is Foundation only.
        self.assertIn("#import <Foundation/Foundation.h>", (ROOT / "Core/SRRunProjection.h").read_text(encoding="utf-8"))

    def test_pages_never_arm_capture_create_a_plan_or_send_on_open(self):
        pages = new_pages()
        for forbidden in ("armForAccount:", "confirmForCurrentAccount:", "beginCapture",
                          "createPlanFromConfiguration", "submitDelivery", "claimNextForRun",
                          "saveLibraryImageData", "startObservation"):
            self.assertNotIn(forbidden, pages)
        # The whole file still has no implicit capture arming or dispatch call.
        source = screens_source()
        for forbidden in ("armForAccount:", "beginCapture", "createPlanFromConfiguration",
                          "submitDelivery", "claimNextForRun", "startObservation"):
            self.assertNotIn(forbidden, source)

    # --- 投影与应用一致性（可在本地执行） ---

    def test_every_phase_constant_has_a_display_label(self):
        projection = project_source()
        declared = set(re.findall(r'NSString \*const (SRRunPhase\w+) = @"', projection))
        self.assertTrue(declared)
        labels = projection.split("+ (NSString *)phaseText:", 1)[1].split("return", 1)[0]
        for name in declared:
            self.assertIn(name + ": @", labels, name)

    def test_filter_constants_match_the_published_list(self):
        projection = project_source()
        declared = re.findall(r'NSString \*const (SRGroupFilter\w+) = @"(\w+)"', projection)
        listed = projection.split("+ (NSArray<NSString *> *)filterIdentifiers {", 1)[1].split("}", 1)[0]
        for name, value in declared:
            self.assertIn(name, listed, name)
        self.assertEqual(len(declared), 5)
        self.assertIn('@"全部"', projection)
        self.assertIn('@"有异常"', projection)

    def test_completed_filter_excludes_abnormal_runs(self):
        projection = project_impl()
        match = projection.split("+ (BOOL)phase:(NSString *)phase matchesFilter:(NSString *)filter {", 1)[1].split("\n}", 1)[0]
        completed = match.split('if ([filter isEqual:SRGroupFilterCompleted])', 1)[1].split(";", 1)[0]
        self.assertIn("SRRunPhaseCompleted", completed)
        self.assertNotIn("SRRunPhaseAbnormal", completed)
        abnormal = match.split('if ([filter isEqual:SRGroupFilterAbnormal])', 1)[1].split(";", 1)[0]
        self.assertIn("SRRunPhaseAbnormal", abnormal)
        self.assertIn("SRRunPhaseUnknown", abnormal)

    def test_text_search_ignores_case_and_diacritics(self):
        projection = project_source()
        search = projection.split("if (query.length) {", 1)[1].split("if (!matched) continue;", 1)[0]
        self.assertIn("NSCaseInsensitiveSearch", search)
        self.assertIn("NSDiacriticInsensitiveSearch", search)
        self.assertIn('@[@"targets", @"targetNames"]', search)

    def test_frozen_target_names_are_not_invented(self):
        projection = project_source()
        cards = projection.split("+ (NSArray<NSDictionary *> *)groupRowsForCards:", 1)[1].split(
            "+ (NSArray<NSDictionary *> *)groupRowsForConfiguration:", 1)[0]
        # Identifiers come from the frozen plan; names are never fabricated.
        self.assertIn('@"targets": identifiers', cards)
        self.assertIn('@"targetNames": @[]', cards)
        self.assertNotIn('@"name": row[@"name"]', cards)

    def test_overview_only_counts_groups_that_have_a_run(self):
        projection = project_source()
        overview = projection.split("+ (NSDictionary *)overviewForGroupRows:", 1)[1].split("\n}", 1)[0]
        self.assertIn("if (summary) {", overview)
        self.assertIn("started++", overview)
        self.assertIn("processed += ", overview)
        self.assertIn("unstarted", overview)

    def test_latest_run_uses_insertion_order_not_wall_clock(self):
        projection = project_source()
        latest = projection.split("+ (NSDictionary *)latestRunInCards:", 1)[1].split("\n}", 1)[0]
        self.assertIn('run[@"creationOrder"]', latest)
        self.assertNotIn("ended_at", latest)
        self.assertNotIn("started_at", latest)
        for terminal in ('@"completed"', '@"ended"'):
            self.assertIn(terminal, latest)

    def test_missing_times_are_never_filled_with_the_page_clock(self):
        projection = project_source()
        time = projection.split("static NSString *SRProjectionFormat", 1)[1].split("\n}", 1)[0]
        self.assertIn("if (!SRProjectionTimeValue(value)) return missing;", time)
        self.assertIn("NSTimeZone.localTimeZone", time)
        self.assertIn('@"yyyy-MM-dd HH:mm"', projection)
        self.assertIn('@"未记录"', projection)
        # A boolean is not a time.
        value = projection.split("static BOOL SRProjectionTimeValue", 1)[1].split("\n}", 1)[0]
        self.assertIn("CFBooleanGetTypeID", value)

    def test_host_source_time_is_printed_raw(self):
        projection = project_source()
        host = projection.split("+ (NSString *)unverifiedHostTimeText:", 1)[1].split("\n}", 1)[0]
        self.assertIn("NSNumberFormatter", host)
        self.assertIn("语义未验证", host)
        self.assertNotIn("NSDate", host)

    def test_frozen_target_identifiers_flow_from_store_to_search(self):
        """A confirmed plan must be searchable by its target identifiers.

        SRStore returns them per card in position order; the projection copies
        them into the row; the search only reads that projection."""
        store = (ROOT / "Core/SRStore.m").read_text(encoding="utf-8")
        cards = store.split("- (NSArray *)ruleCardsForPlan:", 1)[1].split("- (NSArray *)historyForRule:", 1)[0]
        # One bounded read for the whole plan, ordered by the frozen position.
        self.assertIn('@"SELECT rule_id,target FROM allocations WHERE plan_id=? ORDER BY rule_id,position"', cards)
        self.assertIn('card[@"targetIdentifiers"]', cards)
        # The existing fields and their behaviour are kept.
        for kept in ('card[@"latestRun"]', 'card[@"accountOccupied"]', 'card[@"initialUnlocked"]',
                     'AS targetCount'):
            self.assertIn(kept, cards)
        # No name is looked up or invented for a frozen plan.
        self.assertNotIn("targetNames", cards)

        projection = project_source()
        rows = projection.split("+ (NSArray<NSDictionary *> *)groupRowsForCards:", 1)[1].split(
            "+ (NSArray<NSDictionary *> *)groupRowsForConfiguration:", 1)[0]
        self.assertIn('[card[@"targetIdentifiers"] isKindOfClass:NSArray.class]', rows)
        self.assertIn('@"targets": identifiers', rows)
        self.assertIn('@"targetNames": @[]', rows)

        # The list searches the projection it already built; only reload reads
        # the store, and no cell or search callback resolves a preview.
        listing = group_list_block()
        self.assertNotIn("smallGroupRulePreview", listing)
        apply = listing.split("- (void)applyFilter {", 1)[1].split("\n}", 1)[0]
        self.assertIn("[SRRunProjection rows:self.allRows matchingText:", apply)
        self.assertNotIn("self.store", apply)
        menu = listing.split("- (void)chooseFilter {", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("self.store", menu)
        self.assertNotIn("self.store", listing.split("- (void)updateSearchResultsForSearchController:", 1)[1]
                         .split("\n}", 1)[0])

    def test_stale_page_identity_is_closed_before_any_active_branch(self):
        detail = detail_block()
        actions = detail.split("- (void)buildActions {", 1)[1].split("\n}", 1)[0]
        # Stale is decided first; no active branch can run for a stale page.
        self.assertLess(actions.index("if (self.replaced)"), actions.index("phaseIsActive:"))
        self.assertLess(actions.index("if (self.replaced)"), actions.index('@"kind": @"start"'))
        self.assertLess(actions.index("if (self.replaced)"), actions.index('@"kind": @"cancel"'))
        start = detail.split("- (void)startPressed {", 1)[1].split("\n}", 1)[0]
        self.assertIn("if (self.replaced)", start)
        self.assertLess(start.index("if (self.replaced)"), start.index("smallGroupRulePreview"))

    def test_stale_detection_is_the_tested_projection_function(self):
        detail = detail_block()
        reload = detail.split("- (void)reload {", 1)[1].split("\n}", 1)[0]
        # The page does not hand-roll the comparison; it calls the pure function
        # that tests/run_projection_test.m executes for all four shapes.
        self.assertIn("[SRRunProjection pageIsStaleForBoundRun:self.runID currentRunID:currentRunID]", reload)
        self.assertNotIn("self.runID.length && run", reload)
        projection = project_source()
        self.assertIn("+ (BOOL)pageIsStaleForBoundRun:", projection)
        # A stale page also stops presenting the other run's numbers.
        self.assertIn("(run && !self.replaced)", reload)

    def test_stale_binding_table_is_executed_locally(self):
        """Run the identity table and pin it to the Objective-C source."""
        projection = project_source()
        body = projection.split("+ (BOOL)pageIsStaleForBoundRun:", 1)[1].split("\n}", 1)[0]
        # The transcription below is only meaningful while the source keeps
        # these two branches and normalises a missing id to nil.
        self.assertIn("if (!bound) return current != nil;", body)
        self.assertIn("return !(current && [current isEqual:bound]);", body)
        self.assertIn("SRProjectionString(boundRunID, nil)", body)
        self.assertIn("SRProjectionString(currentRunID, nil)", body)

        # 1. a "no run" page after a run appeared
        self.assertTrue(evaluate_stale_binding(None, "run-new"))
        # ... still usable while no run exists
        self.assertFalse(evaluate_stale_binding(None, None))
        # 2. bound to an old run, current differs
        self.assertTrue(evaluate_stale_binding("run-old", "run-new"))
        # 3. bound to a run that is now missing
        self.assertTrue(evaluate_stale_binding("run-old", None))
        # 4. after this page's own successful start it adopts the new id
        self.assertFalse(evaluate_stale_binding("run-new", "run-new"))
        # empty strings are "no run", never a real identity
        self.assertFalse(evaluate_stale_binding("", ""))
        self.assertTrue(evaluate_stale_binding("", "run-x"))
        self.assertFalse(evaluate_stale_binding("run-x", "run-x"))

    def test_only_a_successful_start_adopts_a_run_identifier(self):
        detail = detail_block()
        confirmed = detail.split("- (void)startConfirmedRule:", 1)[1].split("\n}", 1)[0]
        self.assertIn("self.execution.currentRunID", confirmed)
        self.assertIn("self.runID = created", confirmed)
        # The adoption happens after the start call, never before it.
        self.assertLess(confirmed.index("startRule:rule account:account"), confirmed.index("self.runID = created"))
        # No other method writes the bound run identifier.
        assignments = re.findall(r"self\.runID\s*=", detail)
        self.assertEqual(len(assignments), 1)

    def test_late_confirmation_rechecks_the_frozen_card_before_starting(self):
        """A confirmation can sit on screen while another entry starts a run.

        The handler must re-read the frozen card for this account and re-check
        every start gate before it issues startRule:.
        """
        detail = detail_block()
        confirmed = detail.split("- (void)startConfirmedRule:(NSString *)rule account:(NSString *)account {", 1)[1].split("\n}", 1)[0]
        # 1. account and page identity first.
        self.assertLess(confirmed.index("[self verified]"), confirmed.index("ruleCardsForPlan"))
        self.assertLess(confirmed.index("if (self.replaced)"), confirmed.index("ruleCardsForPlan"))
        self.assertLess(confirmed.index("[account isEqual:self.account]"), confirmed.index("ruleCardsForPlan"))
        # 2-3. the frozen plan is re-read for this account and the card resolved.
        self.assertIn("[self.store ruleCardsForPlan:self.planID account:account error:NULL]", confirmed)
        self.assertIn("SRCardForRule(cards, self.ruleID)", confirmed)
        # 4. a run that appeared during the confirmation closes the path.
        self.assertIn('if ([card[@"latestRun"] isKindOfClass:NSDictionary.class]) {', confirmed)
        # 5. the remaining start gates are re-checked as well.
        for gate in ('if (!card)',
                     'if ([card[@"latestRun"] isKindOfClass:NSDictionary.class])',
                     '[card[@"targetCount"] unsignedIntegerValue] > SRRunProjectionTargetLimit',
                     '[card[@"initialUnlocked"] isEqual:@YES]',
                     '[card[@"accountOccupied"] isEqual:@YES]'):
            self.assertIn(gate, confirmed, gate)
        # 6-7. the frozen preview and the command come after every gate.
        command = confirmed.index("[self.execution startRule:rule account:account error:&error]")
        for step in ('ruleCardsForPlan', 'smallGroupRulePreview', 'SRRunProjectionTargetLimit',
                     '@"initialUnlocked"', '@"accountOccupied"', 'latestRun'):
            self.assertLess(confirmed.index(step), command, step)
        # 8. the identifier is adopted only after a successful start.
        self.assertLess(command, confirmed.index("self.runID = created"))
        # 9. every refusal returns instead of falling through to the command.
        for guard in ('if (!card) {', 'if ([card[@"latestRun"] isKindOfClass:NSDictionary.class]) {',
                      'if (![card[@"initialUnlocked"] isEqual:@YES]) {',
                      'if ([card[@"accountOccupied"] isEqual:@YES]) {'):
            body = confirmed.split(guard, 1)[1].split("}", 1)[0]
            self.assertIn("return;", body, guard)

    def test_start_gate_table_is_executed_locally(self):
        """Run the start gate and pin it to the source conditions."""
        detail = detail_block()
        confirmed = detail.split("- (void)startConfirmedRule:(NSString *)rule account:(NSString *)account {", 1)[1].split("\n}", 1)[0]
        # The transcription below is only meaningful while the source keeps
        # these four conditions and treats a missing card as a refusal.
        self.assertIn('if ([card[@"latestRun"] isKindOfClass:NSDictionary.class])', confirmed)
        self.assertIn('[card[@"targetCount"] unsignedIntegerValue] > SRRunProjectionTargetLimit', confirmed)
        self.assertIn('![card[@"initialUnlocked"] isEqual:@YES]', confirmed)
        self.assertIn('[card[@"accountOccupied"] isEqual:@YES]', confirmed)
        self.assertIn("if (!card) {", confirmed)

        clean = {"latestRun": "NSNull", "targetCount": 3, "initialUnlocked": True, "accountOccupied": False}
        self.assertTrue(card_allows_start(clean))
        # Regression: a run appeared while the confirmation was on screen.
        self.assertFalse(card_allows_start(dict(clean, latestRun={"id": "run-new"})))
        self.assertFalse(card_allows_start(dict(clean, targetCount=21)))
        self.assertFalse(card_allows_start(dict(clean, initialUnlocked=False)))
        self.assertFalse(card_allows_start(dict(clean, accountOccupied=True)))
        # A card that is no longer in the frozen plan is refused too.
        self.assertFalse(card_allows_start(None))

    def test_early_start_also_checks_the_card_before_the_preview(self):
        detail = detail_block()
        start = detail.split("- (void)startPressed {", 1)[1].split("\n}", 1)[0]
        self.assertLess(start.index('[card[@"latestRun"]'), start.index("smallGroupRulePreview"))
        self.assertLess(start.index("if (self.replaced)"), start.index("smallGroupRulePreview"))

    def test_group_list_passes_the_run_identity_it_displayed(self):
        listing = group_list_block()
        route = listing.split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1)[1]
        self.assertIn('[row[@"runID"] isKindOfClass:NSString.class]', route)
        self.assertIn('row[@"identifier"]', route)
        # Passing a hard-coded nil would make a started group look unstarted.
        self.assertNotIn('row[@"identifier"], nil)', route)

    # --- 冻结配置错配（2026-10-27 收口） ---

    def test_home_freezes_the_configuration_of_the_content_it_shows(self):
        """The home must carry the content's own configuration, not the live one.

        A preview is captured under the settings of that moment and a prepared
        content persists its configuration row, so the groups must be projected
        from the same snapshot as the envelope. Re-reading settings here is the
        reported mismatch.
        """
        interface = screens_source().split("@interface SROperationsHomeScreen", 1)[1].split("@end", 1)[0]
        self.assertIn("@property(nonatomic, copy, nullable) NSDictionary *frozenConfiguration;", interface)
        home = home_block()
        resolve = home.split("- (BOOL)resolveContent:(NSError **)error {", 1)[1].split("\n}", 1)[0]
        # The in-memory preview: the configuration saved with the capture.
        preview = resolve.split("if (preview &&", 1)[1].split("return YES;", 1)[0]
        self.assertIn('self.frozenConfiguration = SRDictionary(self.capture.status[@"configuration"]);', preview)
        # The prepared content: the persisted frozen configuration row.
        current = resolve.split("if (current) {", 1)[1].split("return YES;", 1)[0]
        self.assertIn('self.frozenConfiguration = SRDictionary(current[@"configuration"]);', current)
        # A confirmed plan keeps resolving its groups from the plan cards.
        self.assertIn("[self.store plan:newest account:self.account", resolve)
        groups = home.split("- (BOOL)loadGroups:(NSError **)error {", 1)[1].split("\n}", 1)[0]
        self.assertIn("NSDictionary *configuration = self.frozenConfiguration;", groups)
        self.assertLess(groups.index("self.frozenConfiguration"), groups.index("configurationForAccount:"))
        self.assertIn("[SRRunProjection groupRowsForConfiguration:configuration]", groups)
        # The frozen configuration reaches the group page with the plan.
        self.assertIn("self.verifyAccount, self.planID, self.frozenConfiguration", home)
        # No display fix may re-read the host, ask for a preview or use the clock.
        self.assertNotIn("smallGroupRulePreview", home)
        self.assertNotIn("[NSDate date]", home)

    def test_frozen_configuration_wins_over_the_later_saved_settings(self):
        """Frozen A and saved B: the list must project A and never B."""
        header = (ROOT / "UI/SRPlanScreens.h").read_text(encoding="utf-8")
        declaration = header.split("SRCreateGroupList", 1)[1].split(");", 1)[0]
        self.assertIn("NSDictionary * _Nullable configuration", declaration)
        interface = screens_source().split("@interface SRGroupListScreen", 1)[1].split("@end", 1)[0]
        self.assertIn("@property(nonatomic, copy, nullable) NSDictionary *configuration;", interface)
        factory = screens_source().split("UIViewController *SRCreateGroupList", 1)[1].split("\n}", 1)[0]
        self.assertIn("screen.planID = planID; screen.configuration = configuration;", factory)

        reload = group_list_block().split("- (void)reload {", 1)[1].split("\n}", 1)[0]
        # Pin the executed mirror below to the source's two conditions.
        self.assertIn("NSDictionary *configuration = self.configuration;", reload)
        self.assertIn("if (!configuration) configuration = [self.store configurationForAccount:self.account error:&error];",
                      reload)
        self.assertLess(reload.index("self.configuration"), reload.index("configurationForAccount:"))

        frozen = {"rules": [{"id": "rule-a", "name": "冻结分组 A",
                             "targets": [{"id": "chat-a1"}, {"id": "chat-a2"}]}]}
        saved = {"rules": [{"id": "rule-b", "name": "当前保存的分组 B",
                            "targets": [{"id": "chat-b1"}]}]}
        chosen = select_group_configuration(frozen, saved)
        self.assertIs(chosen, frozen)
        self.assertEqual(group_configuration_rows(chosen), group_configuration_rows(frozen))
        self.assertNotEqual(group_configuration_rows(chosen), group_configuration_rows(saved))
        self.assertEqual([r["identifier"] for r in group_configuration_rows(chosen)], ["rule-a"])
        self.assertEqual([r["targetCount"] for r in group_configuration_rows(chosen)], [2])
        self.assertNotIn("rule-b", str(group_configuration_rows(chosen)))

    def test_group_list_without_any_content_is_still_read_only(self):
        """No plan and no frozen configuration: view only, no command rows."""
        listing = group_list_block()
        for forbidden in ("startRule:", "pauseForAccount:", "resumeRun:", "cancelRun:", "endRun:",
                          "smallGroupRulePreview"):
            self.assertNotIn(forbidden, listing, forbidden)
        self.assertIn("self.readOnly = YES", listing)
        # The saved settings are only a fallback when nothing was handed in.
        self.assertIn("if (!configuration) configuration = [self.store configurationForAccount:self.account error:&error];",
                      listing)
        # A read-only page never opens the placeholder-only nil-plan detail.
        route = listing.split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1)[1]
        self.assertIn("if (self.readOnly) { [self showReadOnlyGroup:row]; return; }", route)
        self.assertNotIn("self.readOnly ? nil : self.planID", route)
        detail = detail_block()
        self.assertIn("if (!self.planID.length || self.problem) { self.actionRows = @[]; return; }", detail)
        self.assertIn("尚未确认内容：只能查看分组名称和目标群，不能发送。", detail)
        # The configuration projections never mark a row executable.
        projection = project_source()
        read_only_rows = projection.split("+ (NSArray<NSDictionary *> *)groupRowsForConfiguration:", 1)[1].split("\n}", 1)[0]
        self.assertIn('@"executable": @NO', read_only_rows)
        self.assertIn('@"runID": NSNull.null', read_only_rows)

    def test_read_only_group_opens_the_targets_of_this_row(self):
        """A read-only group shows the targets it was projected with.

        The row already carries name/targets/targetNames from the content's
        frozen configuration, so the viewer draws them directly instead of
        opening a nil-plan detail page or re-reading anything.
        """
        listing = group_list_block()
        viewer = listing.split("- (void)showReadOnlyGroup:(NSDictionary *)row {", 1)[1].split("\n}", 1)[0]
        for field in ('row[@"name"]', 'row[@"targets"]', 'row[@"targetNames"]'):
            self.assertIn(field, viewer, field)
        # The existing read-only text viewer, with the page's account check.
        self.assertIn("SRSourceTextScreen", viewer)
        self.assertIn("viewer.verifyAccount = self.verifyAccount;", viewer)
        self.assertIn('viewer.title = @"分组目标（只读）"', viewer)
        # The local mirror below reproduces exactly these two line shapes.
        self.assertIn('@"%lu. %@（%@）"', viewer)
        self.assertIn('@"%lu. %@"', viewer)
        # No plan, no detail page, no preview call, no host or media access.
        for forbidden in ("SRCreateRunDetail", "SRCreatePlan", "smallGroupRulePreview",
                          "configurationForAccount:", "self.store", "imageAssets", "[NSDate date]"):
            self.assertNotIn(forbidden, viewer, forbidden)
        # It is reached only after the page's own account verification.
        route = listing.split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1)[1]
        self.assertLess(route.index("if (![self verified]) return;"), route.index("[self showReadOnlyGroup:row]"))

        # Frozen A differs from saved B: the opened viewer shows A's targets.
        frozen = {"rules": [{"id": "rule-a", "name": "冻结分组 A",
                             "targets": [{"id": "chat-a1", "name": "群 A1"},
                                         {"id": "chat-a2", "name": "群 A2"}]}]}
        saved = {"rules": [{"id": "rule-b", "name": "当前保存的分组 B",
                            "targets": [{"id": "chat-b1", "name": "群 B1"}]}]}
        rows = group_configuration_rows(select_group_configuration(frozen, saved))
        self.assertEqual([row["identifier"] for row in rows], ["rule-a"])
        # The row the page projects is the one the viewer is fed.
        projected = {"identifier": "rule-a", "name": "冻结分组 A", "targetCount": 2,
                     "targets": ["chat-a1", "chat-a2"], "targetNames": ["群 A1", "群 A2"]}
        self.assertEqual(rows[0]["name"], "冻结分组 A")
        body = read_only_viewer_body(projected)
        self.assertIn("冻结分组 A", body)
        self.assertIn("chat-a1", body)
        self.assertIn("chat-a2", body)
        self.assertIn("群 A1", body)
        self.assertNotIn("chat-b1", body)
        self.assertNotIn("群 B1", body)

    # --- 旧计划页的命令入口（2026-10-27 收口） ---

    def test_old_plan_page_no_longer_owns_a_command_entry(self):
        """The rule menu with start/pause/continue/cancel/end is removed.

        Otherwise the old page could start a run without the detail page's late
        re-check of the frozen card.
        """
        old = record_screen_block()
        self.assertNotIn("- (void)ruleActions:", old)
        self.assertNotIn("performExecution", old)
        for command in ("startRule:", "pauseForAccount:", "resumeRun:", "cancelRun:", "endRun:",
                        "smallGroupRulePreview:"):
            self.assertNotIn(command, old, command)
        # The whole file keeps exactly one start site: the B-2 detail page.
        self.assertEqual(screens_source().count("startRule:"), 1)
        self.assertIn("[self.execution startRule:rule account:account error:&error]", detail_block())
        # No second execution state source was introduced for the old page.
        for forbidden in ("currentTask", "latestRunForAccount", "secondRunState"):
            self.assertNotIn(forbidden, old)

    def test_old_plan_page_routes_a_rule_row_to_the_new_detail_page(self):
        old = record_screen_block()
        route = old.split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:", 1)[1]
        open_rule = route.split("if (self.kind == SRRecordPlan) {", 1)[1].split("return;", 1)[0]
        self.assertIn("[self openRule:row]", open_rule)
        pushed = old.split("- (void)openRule:(NSDictionary *)rule {", 1)[1].split("\n}", 1)[0]
        self.assertIn("SRCreateRunDetail(self.store, self.execution, self.account", pushed)
        self.assertIn("self.verifyAccount", pushed)
        # account + planID + ruleID + the run the row displayed.
        self.assertIn("self.identifier", pushed)
        self.assertIn('rule[@"id"]', pushed)
        self.assertIn('rule[@"latestRun"]', pushed)
        self.assertIn("isKindOfClass:NSString.class] ? run : nil", pushed)
        # The old page has exactly one route into the detail page and no menu.
        self.assertEqual(old.count("SRCreateRunDetail"), 1)
        self.assertNotIn("UIAlertController alertControllerWithTitle:rule[", old)
        # The rule section no longer promises an action menu.
        self.assertIn("点击规则进入执行详情", old)
        self.assertNotIn("点击规则可操作或查看历史", old)

    def test_plan_history_and_exception_views_are_still_reachable(self):
        old = record_screen_block()
        # Plan list, rule history and exceptions still exist and still read.
        self.assertIn("screen.kind = SRRecordPlans", screens_source())
        self.assertIn("historyForRule:", old)
        self.assertIn("exceptionsForRun:", old)
        self.assertIn("SRRecordHistory", old)
        self.assertIn("SRRecordExceptions", old)
        # The history route removed from the old menu is kept on the detail page.
        detail = detail_block()
        self.assertIn('@"查看本组历史批次（只读）"', detail)
        self.assertIn('@"kind": @"history"', detail)
        self.assertIn("history.kind = SRRecordHistory", detail)
        history = detail.split("- (void)historyPressed {", 1)[1].split("\n}", 1)[0]
        # Read-only: it only opens the paged history screen for this group.
        for command in ("startRule:", "pauseForAccount:", "resumeRun:", "cancelRun:", "endRun:"):
            self.assertNotIn(command, history, command)
        self.assertIn("history.identifier = self.ruleID;", history)
        # A stale page keeps offering nothing, not even the history row.
        actions = detail.split("- (void)buildActions {", 1)[1].split("\n}", 1)[0]
        self.assertLess(actions.index("if (self.replaced)"),
                        actions.index("[self historyActions]"))

    # --- 注册 ---

    def test_new_sources_and_tests_are_registered(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("Core/SRRunProjection.m", makefile)
        workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
        self.assertIn("tests/run_projection_test.m", workflow)
        self.assertIn('"$RUNNER_TEMP/run-projection-test"', workflow)
        syntax = (ROOT / "tools/syntax_check.py").read_text(encoding="utf-8")
        self.assertIn("'Core/SRRunProjection.m'", syntax)
        self.assertIn("'tests/run_projection_test.m'", syntax)


if __name__ == "__main__":
    unittest.main()
