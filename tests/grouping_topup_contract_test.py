"""Source contracts for grouping top-up.

The behaviour itself (which rule gets filled, in which order, and that a custom
rule is never touched) is asserted by tests/group_planner_test.m on macOS CI.
These contracts only pin the invariants that must hold regardless of build:
the grouping planner carries no execution limit, the capacity is a 100/200
grouping spec, and the app passes its real limit in from one place.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class GroupingTopUpContracts(unittest.TestCase):
    def test_planner_never_hardcodes_the_execution_limit(self):
        """The 20-group range is a test gate, not a grouping constant.

        Opening the gate must not require editing the grouping logic, and no
        stored capacity may ever be the test value.
        """
        planner = read("Core/SRGroupPlanner.m")
        literals = re.findall(r"(?<![0-9])20(?![0-9])", planner)
        self.assertEqual(literals, [], "the grouping planner must not hardcode the 20-group limit")
        # The limit arrives as a parameter instead.
        self.assertIn("executionLimit:(NSUInteger)executionLimit", planner)
        self.assertIn("MIN(capacity, executionLimit)", planner)

    def test_capacity_is_only_a_grouping_spec(self):
        planner = read("Core/SRGroupPlanner.m")
        configuration = read("Core/SRConfiguration.m")
        self.assertIn("[capacity isEqual:@100] || [capacity isEqual:@200]", planner)
        self.assertIn("[@[@100, @200] containsObject:capacity]", configuration)
        # A custom rule may not claim a capacity.
        self.assertIn('if ([origin isEqual:@"custom"]) @throw @"custom rule with capacity";', configuration)

    def test_only_automatic_rules_are_topped_up(self):
        planner = read("Core/SRGroupPlanner.m")
        self.assertIn('![rule[@"origin"] isEqual:@"custom"]', planner)
        self.assertIn('updated[@"origin"] = @"auto"; updated[@"capacity"] = @(capacity);', planner)

    def test_generated_rules_record_their_provenance(self):
        planner = read("Core/SRGroupPlanner.m")
        self.assertIn('@"origin": custom ? @"custom" : @"auto"', planner)
        self.assertIn('if (!custom) created[@"capacity"] = @(size);', planner)
        # Reporting: top-up and generation stay separate numbers.
        self.assertIn('@"topUpRules": topUps', planner)
        self.assertIn('@"assignedCount": @(cursor - generatedFrom)', planner)

    def test_app_passes_the_real_limit_from_one_place(self):
        panel = read("UI/SRPanel.m")
        self.assertIn("executionLimit:SRRunProjectionTargetLimit", panel)
        # The hand-picked entry declares its intent in Core, not by UI copy.
        self.assertIn("intent:SRGroupingIntentCustom", panel)
        self.assertIn("intent:SRGroupingIntentAutomatic", panel)

    def test_the_two_intents_are_separated_in_core(self):
        planner = read("Core/SRGroupPlanner.m")
        # The top-up pass is skipped entirely for a hand-picked request, so the
        # rows the user selected are never consumed by an earlier rule.
        self.assertIn("BOOL topUp = (intent == SRGroupingIntentAutomatic);", planner)
        self.assertIn('if (topUp && ![rule[@"origin"] isEqual:@"custom"]) {', planner)
        # Created rules take their provenance from the intent.
        self.assertIn("BOOL custom = (intent == SRGroupingIntentCustom);", planner)
        header = read("Core/SRGroupPlanner.h")
        self.assertIn("SRGroupingIntentCustom", header)
        self.assertIn("never", header)
        # No UI-side flag decides this any more.
        self.assertNotIn('@"origin": @"custom"', read("UI/SRPanel.m"))

    def test_empty_pool_is_a_zero_result_but_empty_top_up_is_refused(self):
        planner = read("Core/SRGroupPlanner.m")
        # A request bigger than zero may legitimately assign nothing.
        self.assertIn("if (!generated && !topUps.count && !requested)", planner)
        self.assertNotIn("Request at least one rule", planner)
        # The UI turns that zero result into "no change" without touching the draft.
        panel = read("UI/SRPanel.m")
        self.assertIn('if (![preview[@"generatedRuleCount"] unsignedIntegerValue] && ![preview[@"topUpCount"] unsignedIntegerValue])', panel)
        self.assertIn('@"没有变更"', panel)

    def test_zero_recipe_is_a_pure_top_up(self):
        """Both counts at 0 must mean "top up only", never "nothing to do"."""
        planner = read("Core/SRGroupPlanner.m")
        self.assertNotIn("Request at least one rule", planner)
        self.assertIn("Nothing to assign", planner)
        panel = read("UI/SRPanel.m")
        self.assertIn("只把新群补进未满的自动分组，不新建规则", panel)
        self.assertIn("两项都为 0 表示只补位、不新建规则", panel)

    def test_settings_row_shows_provenance_not_the_test_gate(self):
        panel = read("UI/SRPanel.m")
        self.assertIn('@"%lu 个群 · 自定义，不参与补位"', panel)
        self.assertIn('@"%lu 个群 · 自动，补位到 %lu"', panel)
        # The row must not print the executable range as the grouping target.
        row = panel.split('@"%lu 个群 · 自动，补位到 %lu"', 1)[1].split(";", 1)[0]
        self.assertIn("capacityForRule", panel)
        self.assertNotIn("SRRunProjectionTargetLimit", row)


if __name__ == "__main__":
    unittest.main()
