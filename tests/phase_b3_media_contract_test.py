"""B-3 read-only pages: message library and shared media budget.

Source contracts plus the registration checks that can run without Apple
tooling. The behaviour of the pure formatting layer is executed by
tests/media_projection_test.m on macOS CI; this file does not execute UIKit and
must not be read as a device result.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def screens():
    return read("UI/SRLibraryScreens.m")


def block(name):
    source = screens()
    return source.split("@implementation " + name, 1)[1].split("@end", 1)[0]


def all_blocks():
    return block("SRLibraryListScreen") + block("SRLibraryItemScreen") + block("SRMediaResourcesScreen")


class B3ReadOnlyPages(unittest.TestCase):
    def test_pages_only_read_and_never_write(self):
        source = screens()
        for forbidden in ("sqlite3", "INSERT INTO", "UPDATE ", "DELETE FROM", "DROP TABLE"):
            self.assertNotIn(forbidden, source)
        # No import, cleanup, delete, task creation or dispatch entry.
        for forbidden in ("saveLibraryImageData", "createLibraryItem", "appendLibraryVersion",
                          "deleteLibraryEntry", "startLibraryTask", "resendLibraryTask",
                          "pruneTemporaryFiles", "pruneUnreferenced", "reserveBytes",
                          "commitReservation", "claimNextForRun", "submitDelivery",
                          "startRule:", "resumeRun:", "cancelRun:", "endRun:",
                          "setSourceMode:", "saveConfiguration"):
            self.assertNotIn(forbidden, source, forbidden)

    def test_pages_use_only_stable_core_reads(self):
        source = screens()
        for api in ("libraryItemsForAccount:", "libraryItem:",
                    "mediaUsageForAccount:", "mediaResourcesForAccount:"):
            self.assertIn(api, source, api)
        # A page never derives its own numbers from the filesystem or host.
        for forbidden in ("NSFileManager", "attributesOfItemAtPath", "contentsOfDirectoryAtPath",
                          "reader groups:", "getMsgHdOrMiddleImg", "prepareImage", "download"):
            self.assertNotIn(forbidden, source, forbidden)

    def test_every_page_verifies_the_account_first(self):
        for name in ("SRLibraryListScreen", "SRLibraryItemScreen", "SRMediaResourcesScreen"):
            body = block(name)
            self.assertIn("accountInvalid = ![self verified]", body, name)
            reload_body = body.split("- (void)reload {", 1)[1].split("\n}", 1)[0]
            # Nothing is read before the account check.
            self.assertLess(reload_body.index("accountInvalid = ![self verified]"),
                            reload_body.index("self.store"), name)

    def test_each_page_has_distinct_empty_failure_and_account_states(self):
        listing = block("SRLibraryListScreen")
        self.assertIn('@"消息库还没有条目"', listing)
        self.assertIn('@"读取失败"', listing)
        self.assertIn('@"账号无法核对或已经改变"', listing)

        item = block("SRLibraryItemScreen")
        self.assertIn('@"没有版本记录"', item)
        self.assertIn('@"读取失败"', item)
        self.assertIn('@"账号无法核对或已经改变"', item)

        media = block("SRMediaResourcesScreen")
        self.assertIn('@"本账号没有已登记的素材"', media)
        self.assertIn('@"用量读取失败"', media)
        self.assertIn('@"资源列表读取失败"', media)
        self.assertIn('@"账号无法核对或已经改变"', media)

    def test_retry_is_explicit_and_never_automatic(self):
        source = screens()
        self.assertEqual(source.count("UIRefreshControl alloc"), 3)
        for name in ("SRLibraryListScreen", "SRLibraryItemScreen", "SRMediaResourcesScreen"):
            body = block(name)
            self.assertIn("viewWillAppear", body)
            # Reload happens on appearance and on a user pull, not on a timer.
            self.assertNotIn("NSTimer", body)
            self.assertNotIn("dispatch_after", body)

    def test_unavailable_media_is_stated_not_faked(self):
        source = screens()
        self.assertIn('@"素材不可用：本地没有该版本的媒体引用"', source)
        self.assertIn("素材不在此页渲染", source)
        # Image versions never open a viewer or read asset bytes.
        self.assertIn('if (![version[@"kind"] isEqual:@"text"]) return;', source)
        self.assertNotIn("dataForPayload", source)
        self.assertNotIn("UIImage", source)

    def test_unknown_kinds_are_not_degraded_to_text(self):
        projection = read("Core/SRMediaProjection.m")
        body = projection.split("+ (NSString *)libraryKindText:", 1)[1].split("\n}", 1)[0]
        self.assertIn('if ([kind isEqual:@"text"]) return @"文字";', body)
        self.assertIn('if ([kind isEqual:@"image"]) return @"图片";', body)
        self.assertIn("未支持", body)

    def test_usage_page_never_shows_an_unreadable_number_as_zero(self):
        projection = read("Core/SRMediaProjection.m")
        summary = projection.split("+ (NSDictionary *)usageSummary:", 1)[1].split("\n}", 1)[0]
        self.assertIn('@"available": @NO', summary)
        self.assertIn('@"usedText": @"未知"', summary)
        self.assertIn('return @"未知";', projection)
        media = block("SRMediaResourcesScreen")
        self.assertIn('@"用量读不到时不显示 0', media)

    def test_pages_mask_on_resign_and_reverify_on_foreground(self):
        """Leaving the app hides what is on screen; returning re-checks the
        account this page was opened with. Lifecycle handling must never stop a
        capture, create a task or start sending."""
        source = screens()
        self.assertEqual(source.count("UIApplicationWillResignActiveNotification"), 3)
        self.assertEqual(source.count("UIApplicationDidBecomeActiveNotification"), 3)

        clears = {
            "SRLibraryListScreen": "[self.rows removeAllObjects]; self.problem = nil; self.more = NO;",
            "SRLibraryItemScreen": "self.entry = nil; self.versions = @[]; self.problem = nil;",
            "SRMediaResourcesScreen": "self.usage = nil; self.resources = @[]; self.usageProblem = nil; self.listProblem = nil;",
        }
        for name, clear in clears.items():
            body = block(name)
            self.assertIn("- (void)resigningActive:", body, name)
            self.assertIn("- (void)becameActive:", body, name)
            resign = body.split("- (void)resigningActive:", 1)[1].split("\n}", 1)[0]
            self.assertIn("self.masked = YES;", resign, name)
            self.assertIn(clear, resign, name)
            # A failed re-check clears the page instead of switching accounts and
            # shows the account notice, not the ordinary mask notice.
            active = body.split("- (void)becameActive:", 1)[1].split("\n}", 1)[0]
            self.assertIn("if (![self verified])", active, name)
            self.assertIn("self.accountInvalid = YES;", active, name)
            self.assertIn("self.masked = NO;", active, name)
            self.assertIn(clear, active, name)
            self.assertIn("[self reload];", active, name)
            # The account branch must be reachable, i.e. not pre-empted by the mask.
            cells = body.split("cellForRowAtIndexPath:", 1)[1]
            self.assertLess(cells.index("if (self.masked)"), cells.index("if (self.accountInvalid)"))
            # The mask is cleared only by a successful reload.
            self.assertIn("self.masked = NO;", body.split("- (void)reload {", 1)[1].split("\n}", 1)[0], name)

        # Lifecycle handlers must not touch capture, tasks or sending.
        for name in ("SRLibraryListScreen", "SRLibraryItemScreen", "SRMediaResourcesScreen"):
            body = block(name)
            lifecycle = (body.split("- (void)resigningActive:", 1)[1].split("@end", 1)[0])
            for forbidden in ("[receiver stop]", "[capture cancel]", "armForAccount", "startRule:",
                              "createLibraryItem", "submitDelivery", "resumeRun:", "capture.tick"):
                self.assertNotIn(forbidden, lifecycle, name)

        # A masked page cannot start any navigation either.
        self.assertEqual(source.count("if (self.masked) return;"), 3)

    def test_masked_state_is_its_own_display(self):
        source = screens()
        self.assertIn('@"内容已隐藏"', source)
        self.assertIn('@"离开前台时已清除本页显示；回到前台会重新核对账号后再读取。"', source)
        # It must not be reported as an account failure or an empty library.
        self.assertNotEqual(source.count('@"内容已隐藏"'), 0)
        for name in ("SRLibraryListScreen", "SRLibraryItemScreen", "SRMediaResourcesScreen"):
            body = block(name)
            rows = body.split("numberOfRowsInSection:", 1)[1].split("\n}", 1)[0]
            self.assertIn("if (self.masked", rows, name)
            self.assertIn("return 1;", rows, name)

    def test_usage_failure_is_confined_to_the_capacity_section(self):
        """A failed usage scan must not hide the resource list, and a failed
        list must not hide a readable capacity."""
        media = block("SRMediaResourcesScreen")
        sections = media.split("numberOfSectionsInTableView:", 1)[1].split("\n}", 1)[0]
        self.assertIn("self.masked || self.accountInvalid", sections)
        self.assertNotIn("usageProblem", sections)
        self.assertNotIn("listProblem", sections)

        rows = media.split("numberOfRowsInSection:", 1)[1].split("\n}", 1)[0]
        self.assertIn("if (section == 0) return self.usageProblem ? 1 : 5;", rows)
        self.assertIn("if (self.listProblem) return 1;", rows)
        # The list branch comes after the capacity branch and is unreachable from it.
        self.assertLess(rows.index("section == 0"), rows.index("listProblem"))

        # The usage problem cell is scoped to section 0.
        cell = media.split("cellForRowAtIndexPath:", 1)[1].split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath", 1)[0]
        self.assertIn("if (path.section == 0 && self.usageProblem)", cell)
        self.assertNotIn("if (self.usageProblem) {", cell)

        header = media.split("titleForHeaderInSection:", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("usageProblem", header)
        footer = media.split("titleForFooterInSection:", 1)[1].split("\n}", 1)[0]
        self.assertIn("section == 0) return self.usageProblem ?", footer)
        self.assertIn("资源列表读取失败不影响上方容量", footer)

        select = media.split("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath", 1)[1].split("\n}", 1)[0]
        self.assertIn("if (path.section == 0 && self.usageProblem) { [self reload]; return; }", select)
        self.assertIn("if (path.section == 1 && self.listProblem) { [self reload]; return; }", select)

    def test_projection_publishes_one_row_count(self):
        projection = read("Core/SRMediaProjection.m")
        body = projection.split("+ (NSDictionary *)resourceSectionForPayload:", 1)[1].split("\n}", 1)[0]
        # The count is derived from the published array, in every state.
        self.assertIn('section[@"rows"] = published;', body)
        self.assertIn('section[@"listedCount"] = @(published.count);', body)
        self.assertNotIn('@(rows.count);', body)

    def test_resource_section_is_decided_by_the_projection(self):
        media = block("SRMediaResourcesScreen")
        self.assertIn("resourceSectionForPayload:", media)
        # Three distinct readings of an empty list.
        self.assertIn('@"unverified"', media)
        self.assertIn('@"truncated_empty"', media)
        self.assertIn('@"本账号没有已登记的素材"', media)
        # An unverified attribution is stated, never rendered as "nothing stored".
        self.assertIn('@"资源归属未验证"', media)
        self.assertIn('@"结果不完整"', media)
        # The shared capacity and the resource list fail independently: the list
        # is still read after the usage scan failed.
        reload = media.split("- (void)reload {", 1)[1].split("\n}", 1)[0]
        self.assertIn("usageProblem = @{", reload)
        self.assertIn("listProblem = @{", reload)
        self.assertLess(reload.index("usageProblem = @{"), reload.index("listProblem = @{"))
        self.assertLess(reload.index("if (!self.usage)"), reload.index("mediaResourcesForAccount"))

    def test_pages_reuse_the_single_text_viewer(self):
        self.assertIn("SRCreateReadOnlyText", screens())
        header = read("UI/SRPlanScreens.h")
        self.assertIn("SRCreateReadOnlyText", header)
        # The library page must not grow a second text implementation.
        self.assertNotIn("@interface SRLibraryTextScreen", screens())


class B3SettingsEntry(unittest.TestCase):
    def test_entries_are_wired_with_a_repeat_guard(self):
        panel = read("UI/SRPanel.m")
        for hook in ("- (void)openLibrary {", "- (void)openMediaResources {",
                     "- (BOOL)canOpenReadOnlyPage {"):
            self.assertIn(hook, panel)
        guard = panel.split("- (BOOL)canOpenReadOnlyPage {", 1)[1].split("\n}", 1)[0]
        self.assertIn("[self checkAccount]", guard)
        self.assertIn("navigation.topViewController != self", guard)
        self.assertIn("navigation.isBeingPresented", guard)
        self.assertIn("navigation.transitionCoordinator", guard)
        self.assertIn("navigation.presentedViewController", guard)
        for caller in ("- (void)openLibrary {", "- (void)openMediaResources {"):
            body = panel.split(caller, 1)[1].split("\n}", 1)[0]
            self.assertIn("if (![self canOpenReadOnlyPage]) return;", body)
            self.assertLess(body.index("canOpenReadOnlyPage"), body.index("pushViewController"))

    def test_read_only_pages_do_not_stop_capture(self):
        panel = read("UI/SRPanel.m")
        verifier = panel.split("- (BOOL (^)(void))readOnlyVerifier {", 1)[1].split("\n}", 1)[0]
        self.assertIn("verifyAccount", verifier)
        # The plan verifier stops the receiver and cancels capture; a read-only
        # page must not reuse it.
        for forbidden in ("[receiver stop]", "[capture cancel]"):
            self.assertNotIn(forbidden, verifier)
        for caller in ("- (void)openLibrary {", "- (void)openMediaResources {"):
            body = panel.split(caller, 1)[1].split("\n}", 1)[0]
            self.assertIn("readOnlyVerifier", body)
            self.assertNotIn("planVerifier", body)

    def test_entries_are_visible_rows_in_the_settings_table(self):
        panel = read("UI/SRPanel.m")
        self.assertIn('@"消息库"', panel)
        self.assertIn('@"资源容量"', panel)
        self.assertIn("if (path.row == 6) [self openLibrary];", panel)
        self.assertIn("if (path.row == 7) [self openMediaResources];", panel)
        self.assertIn("if (section == 4) return 8;", panel)

    def test_unwired_capabilities_stay_unavailable(self):
        """Source switching, import and library dispatch are not exposed."""
        source = screens() + read("UI/SRPanel.m")
        for forbidden in ("setSourceMode", "库派发", "立即导入", "从消息库发送"):
            self.assertNotIn(forbidden, source, forbidden)


class B3Registration(unittest.TestCase):
    def test_new_sources_and_tests_are_registered(self):
        makefile = read("Makefile")
        self.assertIn("Core/SRMediaProjection.m", makefile)
        self.assertIn("UI/SRLibraryScreens.m", makefile)
        workflow = read(".github/workflows/build.yml")
        self.assertIn("tests/media_projection_test.m", workflow)
        self.assertIn('"$RUNNER_TEMP/media-projection-test"', workflow)
        syntax = read("tools/syntax_check.py")
        for unit in ("Core/SRMediaProjection.m", "UI/SRLibraryScreens.m", "tests/media_projection_test.m"):
            self.assertIn(unit, syntax, unit)

    def test_version_is_the_next_functional_release(self):
        version = re.search(r'#define SR_PLUGIN_VERSION @"([^"]+)"', read("Core/SRVersion.h")).group(1)
        self.assertNotEqual(version, "0.2.21",
                            "a new functional build must not reuse the previous package version")


if __name__ == "__main__":
    unittest.main()
