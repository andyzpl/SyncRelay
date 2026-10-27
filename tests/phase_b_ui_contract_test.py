"""Phase B UI wiring contracts; UIKit rendering still requires a device check."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def evaluate_home_top_guard(condition, home_exists, home_is_top):
    """Evaluate the source's home/top comparison guard.

    The guard is the expression from openSettingsFromNavigation that compares
    the home controller with the top of the presented stack. It is evaluated
    here so the direction of the comparison is actually executed, not merely
    matched as text. Returns True when the guard rejects the request.

    Only the shapes this guard can take are supported; anything else raises,
    so an unexpected rewrite cannot pass silently.
    """
    text = re.sub(r"\s+", " ", condition).strip()
    # The whole condition, including a possible "!home ||" existence part.
    exists_part = ""
    if text.startswith("!home ||"):
        exists_part = "!home ||"
        text = text[len("!home ||"):].strip()
    if not exists_part:
        if not text.startswith("!home"):
            raise AssertionError(f"unsupported guard shape: {condition!r}")
        text = text[len("!home"):].strip()
        if text.startswith("||"):
            text = text[2:].strip()

    # The comparison itself, in either direction.
    if text == "home != navigation.topViewController":
        comparison = "ne"
    elif text == "home == navigation.topViewController":
        comparison = "eq"
    else:
        raise AssertionError(f"unsupported guard shape: {condition!r}")

    if not home_exists:
        # "!home" already rejects before the comparison is reached.
        return True
    # "home != top" rejects when the home is NOT the visible page, so the
    # normal single-home stack (home is the top) is allowed.
    different = home_exists != home_is_top
    rejects = different if comparison == "ne" else not different
    return rejects


class PhaseBUIContracts(unittest.TestCase):
    def text(self, path):
        return (ROOT / path).read_text(encoding="utf-8")

    def test_operations_home_is_a_projection_only_entry(self):
        header = self.text("UI/SRPlanScreens.h")
        source = self.text("UI/SRPlanScreens.m")
        self.assertIn("SRCreateOperationsHome", header)
        self.assertIn('self.title = @"SyncRelay 运营"', source)
        self.assertIn('打开本页不会开始捕获、创建计划或发送', source)
        home = source.split("@interface SROperationsHomeScreen", 1)[1]
        self.assertNotIn("armForAccount:", home)
        self.assertNotIn("startRule:", home)
        self.assertNotIn("confirmForCurrentAccount:", home)

    def test_home_routes_to_existing_preview_and_plan_pages(self):
        source = self.text("UI/SRPlanScreens.m")
        home = source.split("@interface SROperationsHomeScreen", 1)[1]
        self.assertIn("SRCreateCapturePreview", home)
        self.assertIn("SRCreatePlanList", home)
        self.assertIn('section == 2 && path.row == 0', home)

    def test_capsule_has_open_and_menu_actions_without_owning_a_window(self):
        header = self.text("UI/SRFloatingProgress.h")
        source = self.text("UI/SRFloatingProgress.m")
        panel = self.text("UI/SRPanel.m")
        self.assertIn("openAction", header)
        self.assertIn("menuAction", header)
        self.assertIn("UITapGestureRecognizer", source)
        self.assertIn("menuButton", source)
        self.assertNotIn("UIWindow alloc", source)
        self.assertIn("openOperationsFromController", panel)
        self.assertIn("showOperationsMenu", panel)

    def test_cancel_menu_is_account_and_run_bound(self):
        session = self.text("Adapter/SRSmallGroupSession.h")
        panel = self.text("UI/SRPanel.m")
        self.assertIn("currentRunID", session)
        self.assertIn("NSString *run = self.smallGroupSession.currentRunID", panel)
        self.assertIn("cancelRun:run account:account", panel)
        self.assertIn("尚未尝试的目标将取消", panel)

    def test_capsule_keeps_three_phase_labels_and_unready_actions_closed(self):
        source = self.text("UI/SRFloatingProgress.m")
        panel = self.text("UI/SRPanel.m")
        for phase in ("running", "paused", "settling", "ready", "waiting"):
            self.assertIn(f'@"{phase}"', source + panel)
        self.assertIn('captureStatus[@"state"] isEqual:@"waiting"', panel)
        self.assertIn('self.capture.preview', panel)

    # --- B-1 entry wiring round (2026-10-27) ---

    def test_idle_floating_entry_opens_the_operations_home(self):
        """The idle floating entry must reach the operations home even with no
        preview, plan, run or history. The old button only opened the settings
        panel, so the home was unreachable while idle."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        # The floating entry button routes to the operations home, not settings.
        self.assertIn("action:@selector(openOperations)", panel)
        self.assertIn("- (void)openOperations {", entry)
        # The idle route reuses the existing capsule route and its account gate.
        self.assertIn("[self openOperationsFromController:nil]", entry)
        # The home itself can show the empty state without any content.
        screens = self.text("UI/SRPlanScreens.m")
        self.assertIn("尚未捕获内容", screens)

    def test_idle_entry_does_not_fabricate_a_capsule_state(self):
        """Reaching the home must not fake ready/completed to force a capsule.
        The idle route reuses the existing entry button instead."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        refresh = entry.split("- (void)refreshFloatingProgress", 1)[1].split("- (void)showOperationsMenu", 1)[0]
        # The idle route is a separate method that only forwards to the capsule
        # route; it must not build a capsule model of its own.
        idle = entry.split("- (void)openOperations {", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("phase", idle)
        self.assertNotIn("model", idle)
        self.assertNotIn("ready", idle)
        self.assertNotIn("completed", idle)
        # The capsule model is still only produced by real content states.
        for guard in ("captureBelongs && self.capture.preview",
                      'captureStatus[@"state"] isEqual:@"waiting"]',
                      "progressBelongsToCurrentAccount",
                      "currentContent", "recentContent"):
            self.assertIn(guard, refresh)

    def test_home_settings_row_is_wired_to_a_real_settings_route(self):
        """The settings row must reach a real settings controller, not only be
        drawn. The route is an explicit callback, not a guessed selector."""
        source = self.text("UI/SRPlanScreens.m")
        header = self.text("UI/SRPlanScreens.h")
        home = source.split("@interface SROperationsHomeScreen", 1)[1]
        # An explicit route callback on the home screen.
        self.assertIn("openSettings", header)
        self.assertIn("openSettings", home)
        # The row is handled in the selection handler, not only painted.
        self.assertIn("path.section == 2 && path.row == 1", home)
        self.assertIn("self.openSettings()", home)
        # The route is a block, never a guessed selector or dynamic message.
        self.assertNotIn("performSelector", home)
        self.assertNotIn("NSSelectorFromString", home)

    def test_home_settings_route_binds_and_revalidates_the_account(self):
        """The settings route carries the account captured when the home was
        opened and re-verifies it, so a changed account is refused instead of
        silently switching."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        self.assertIn("openSettings", entry)
        self.assertIn("verifyAccount:account", entry)
        # The home must be dismissed/returned safely around the settings page.
        self.assertIn("presentingViewController", entry)

    def test_settings_closes_back_to_the_home_without_dismissing_it(self):
        """The settings panel is stacked on the home, so closing it pops back to
        the home instead of dismissing the whole modal."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        self.assertIn("returnsToOperationsHome", panel)
        route = entry.split("- (void)openSettingsFromNavigation:", 1)[1].split("\n}", 1)[0]
        self.assertIn("returnsToOperationsHome = YES", route)
        self.assertIn("pushViewController:panel animated:YES", route)
        # The close path pops when the panel is stacked on the home. The pop has
        # to be inside the stacked branch itself, otherwise a dismissal would
        # tear the home down together with the settings panel.
        close = panel.split("- (void)close {", 1)[1].split("\n- (void)save", 1)[0]
        stacked = close.split("returnsToOperationsHome &&", 1)[1]
        stacked = stacked.split("if (!self.dirty)", 1)[1].split("\n", 1)[0]
        self.assertIn("popViewControllerAnimated:YES", stacked)
        self.assertNotIn("dismissViewControllerAnimated", stacked)
        # The unsaved-draft guard is kept in both close paths.
        self.assertEqual(close.count("放弃未保存的修改"), 2)
        # The standalone settings entry still dismisses as before.
        self.assertIn("dismissViewControllerAnimated:YES completion:self.didClose", close)

    # --- review round (2026-10-27): the three findings below ---

    def test_settings_panel_is_located_in_the_whole_stack_not_the_root(self):
        """The settings panel must be found by scanning the presented stack.
        The root is the home in the home->settings stack and a sub-page above
        the panel when the panel pushed one, so reading the first controller
        reports the wrong dirty/idle/experiment/countdown state."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        self.assertIn("- (SRPanel *)presentedSettingsPanel {", entry)
        locator = entry.split("- (SRPanel *)presentedSettingsPanel {", 1)[1].split("\n}", 1)[0]
        # It scans the whole stack and matches on the settings panel type.
        self.assertIn("self.presented.viewControllers", locator)
        self.assertIn("isKindOfClass:SRPanel.class", locator)
        # The three guards must use the locator, not the root controller.
        self.assertNotIn("entry.presented.viewControllers.firstObject", entry)
        self.assertEqual(entry.count("[entry presentedSettingsPanel]"), 3)
        # Each guard still reads the real state from that panel.
        for state in ("panel.dirty", "panel.ownsIdleTimer", "panel.singleTextSendEnabled",
                      "panel.singleImageSendEnabled", "panel.textCountdown", "panel.imageCountdown"):
            self.assertIn(state, entry)

    def test_settings_route_does_not_form_a_retain_cycle(self):
        """The navigation owns the home and the home owns the settings callback,
        so the callback must capture the navigation weakly and fetch it back
        safely at call time."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        route = entry.split("- (void)openOperationsFromController:", 1)[1].split("\n}", 1)[0]
        self.assertIn("__weak UINavigationController *weakNavigation", route)
        # The block fetches the navigation back instead of capturing it strongly.
        self.assertIn("UINavigationController *current = weakNavigation;", route)
        # The block must not capture the navigation itself.
        block = route.split("void (^openSettings)(void) = ^void {", 1)[1].split("\n    };", 1)[0]
        self.assertNotIn("= navigation;", block)
        self.assertNotIn(":navigation ", block)
        # The entry itself is captured weakly too.
        self.assertIn("__weak typeof(self) weakSelf = self;", route)

    def test_settings_route_rejects_a_stale_or_repeated_request(self):
        """The callback must refuse a navigation this entry no longer manages,
        a home that is no longer the root, a stack that is transitioning, and a
        settings panel that is already on the stack."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        route = entry.split("- (void)openSettingsFromNavigation:", 1)[1].split("\n}", 1)[0]
        # The managed navigation must still be the one the entry presents.
        self.assertIn("if (navigation != self.presented) return;", route)
        # The originating home must still be the root of that stack.
        self.assertIn("navigation.viewControllers.firstObject", route)
        self.assertIn('isEqualToString:@"SyncRelay 运营"', route)
        # No second settings page on the same stack.
        self.assertIn("if ([self presentedSettingsPanel]) return;", route)
        # No re-entry while presenting or dismissing.
        self.assertIn("navigation.isBeingPresented", route)
        self.assertIn("navigation.isBeingDismissed", route)
        self.assertIn("navigation.transitionCoordinator", route)
        # The caller also re-checks the ownership before it routes.
        caller = entry.split("- (void)openOperationsFromController:", 1)[1].split("\n}", 1)[0]
        self.assertIn("current != entry.presented", caller)

    def test_the_settings_route_keeps_the_original_guard_conditions(self):
        """The route guards must stay strict: no default-yes, no removed
        check and no relaxed condition."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        route = entry.split("- (void)openSettingsFromNavigation:", 1)[1].split("\n}", 1)[0]
        # Every early return is a refusal, never an allowance. The only YES is
        # the stacked marker on the panel itself, not a relaxed guard.
        self.assertNotIn("return YES", route)
        self.assertNotIn("panelIdle = YES", route)
        self.assertIn("!verify()", route)
        self.assertIn("UIApplicationStateActive", route)
        self.assertEqual(route.count("return;"), 7)
        # The settings panel still receives the shared objects.
        for shared in ("panel.store = self.store", "panel.capture = self.capture",
                       "panel.receiver = self.receiver", "panel.smallGroupSession = self.smallGroupSession"):
            self.assertIn(shared, route)

    # --- final targeted fix (2026-10-27): the home/top comparison direction ---

    def route_guard_order(self):
        """The ordered guard expressions of openSettingsFromNavigation, taken
        from the source. Returns the list of condition strings."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        route = entry.split("- (void)openSettingsFromNavigation:", 1)[1].split("\n}", 1)[0]
        guards = []
        for line in route.split("\n"):
            line = line.strip()
            if line.startswith("if (") and line.endswith(") return;"):
                guards.append(line[len("if ("):-len(") return;")].strip())
            elif line.startswith("navigation.transitionCoordinator") or line.startswith("navigation.presentedViewController"):
                # The last guard spans two lines.
                guards[-1] = guards[-1] + " || " + line.rstrip(";").strip()
        return guards

    def test_route_allows_a_normal_request_that_reaches_the_settings_push(self):
        """A managed navigation that holds only the operations home, with a
        valid account, no transition and no settings panel, must be allowed to
        create and push the settings panel. The home/top comparison must not
        reject this normal case."""
        guards = self.route_guard_order()
        self.assertTrue(guards)
        # The home/top guard is the one under test.
        home_guard = [g for g in guards if "topViewController" in g]
        self.assertEqual(len(home_guard), 1)
        condition = home_guard[0]
        # A managed navigation with only the home: the home IS the top.
        home_is_top = True
        home_exists = True
        self.assertFalse(evaluate_home_top_guard(condition, home_exists, home_is_top),
                         "the normal single-home case must not be rejected")
        # The rejection must be for a home that is NOT the top, not the reverse.
        self.assertTrue(evaluate_home_top_guard(condition, home_exists, not home_is_top),
                        "a home that is not the visible page must be rejected")

    def test_route_guard_direction_is_locked_to_the_top_comparison(self):
        """The guard must compare the home against the top of the stack with
        '!=' and reject when they differ. The reversed '==' would accept a
        stacked page and reject the normal case."""
        guards = self.route_guard_order()
        condition = [g for g in guards if "topViewController" in g][0]
        # The comparison operator is locked: home != navigation.topViewController.
        self.assertIn("home != navigation.topViewController", condition)
        self.assertNotIn("home == navigation.topViewController", condition)
        # The rejection is expressed as "the home is not the top".
        self.assertRegex(condition, r"home\s*!=\s*navigation\.topViewController")

    def test_route_still_refuses_the_other_cases(self):
        """A stacked page on top, an existing settings panel, a navigation that
        is no longer managed and a stack in transition must all be refused."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        route = entry.split("- (void)openSettingsFromNavigation:", 1)[1].split("\n}", 1)[0]
        # The navigation must still be the managed one.
        self.assertIn("if (navigation != self.presented) return;", route)
        # A settings panel anywhere in the stack blocks a second one.
        self.assertIn("if ([self presentedSettingsPanel]) return;", route)
        # A transition or a modal on the stack blocks the request.
        self.assertIn("navigation.isBeingPresented", route)
        self.assertIn("navigation.isBeingDismissed", route)
        self.assertIn("navigation.transitionCoordinator", route)
        self.assertIn("navigation.presentedViewController", route)
        # The account is still bound and re-verified.
        self.assertIn("!account.length", route)
        self.assertIn("!verify()", route)

    def test_route_guard_conditions_are_not_bypassed(self):
        """No guard may be turned into an allowance, and the push must still be
        reachable after all of them."""
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        route = entry.split("- (void)openSettingsFromNavigation:", 1)[1].split("\n}", 1)[0]
        body = route.split("\n", 1)[1]
        # Every guard is a refusal.
        self.assertNotIn("return YES", route)
        self.assertNotIn("allow = YES", route)
        # The push is still the last action of the route.
        self.assertIn("[navigation pushViewController:panel animated:YES]", body)
        # The panel is still created before it is pushed.
        self.assertLess(route.index("SRPanel *panel = [[SRPanel alloc]"),
                        route.index("[navigation pushViewController:panel animated:YES]"))

    def test_capsule_body_tap_opens_the_home_even_when_action_is_open(self):
        """The capsule body must open the operations home for waiting, ready and
        completed states. The old guard refused the body tap for action=open."""
        source = self.text("UI/SRFloatingProgress.m")
        self.assertIn("- (void)openPressed", source)
        body = source.split("- (void)openPressed {", 1)[1].split("\n", 1)[0]
        self.assertIn("self.openAction()", body)
        self.assertNotIn('isEqual:@"open"', body)
        # A drag must not be reported as a body tap.
        self.assertIn("requireGestureRecognizerToFail:pan", source)

    def test_capsule_buttons_and_menu_are_excluded_from_the_body_tap(self):
        """Button and menu touches must not also fire the body tap."""
        source = self.text("UI/SRFloatingProgress.m")
        gate = source.split("shouldReceiveTouch:", 1)[1].split("\n@end", 1)[0]
        self.assertIn("self.actionButton", gate)
        self.assertIn("self.menuButton", gate)
        # Pause/continue keeps its own action; the body tap never replaces it.
        self.assertIn('isEqual:@"pause"', source)
        self.assertIn("self.action()", source)

    def test_home_open_never_arms_capture_or_sends(self):
        """Opening the home must not arm capture, sample, confirm or send."""
        source = self.text("UI/SRPlanScreens.m")
        home = source.split("@interface SROperationsHomeScreen", 1)[1]
        for forbidden in ("armForAccount:", "startRule:", "confirmForCurrentAccount:",
                          "beginCapture", "togglePauseForCurrentAccount", "submitDelivery"):
            self.assertNotIn(forbidden, home)
        panel = self.text("UI/SRPanel.m")
        entry = panel.split("@implementation SREntry", 1)[1]
        route = entry.split("- (void)openOperations {", 1)[1].split("\n}", 1)[0]
        for forbidden in ("armForAccount:", "confirmForCurrentAccount:", "submitDelivery",
                          "resumeRun", "togglePauseForCurrentAccount"):
            self.assertNotIn(forbidden, route)


if __name__ == "__main__":
    unittest.main()
