import unittest
from unittest.mock import Mock, patch

import github_release


def release(version, *, draft=False, prerelease=False):
    return {"tag_name": f"v{version}", "draft": draft, "prerelease": prerelease}


def automated_draft(*assets):
    return dict(
        release("0.3.1", draft=True),
        id=123,
        target_commitish="previous",
        author={"login": "github-actions[bot]"},
        published_at=None,
        assets=[{"name": name, "state": "uploaded"} for name in assets],
    )


def appcast(build):
    return f"""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><item><sparkle:version>{build}</sparkle:version></item></channel>
    </rss>
    """


class ReleaseTests(unittest.TestCase):
    def test_new_release_can_resume_an_unpublished_draft(self):
        records = [release("0.3.1", draft=True), release("0.2.0")]
        feed = Mock(return_value=appcast(2))
        self.assertTrue(github_release.needs_release("0.3.1", 4, records, feed))
        feed.assert_called_once_with("v0.2.0")

    def test_existing_release_stays_untouched_even_after_rollback(self):
        records = [release("0.3.1", prerelease=True)]
        feed = Mock()
        self.assertFalse(github_release.needs_release("0.3.1", 4, records, feed))
        feed.assert_not_called()

    def test_build_must_exceed_every_published_build_including_prereleases(self):
        records = [release("0.3.0", prerelease=True), release("0.2.0")]
        with self.assertRaisesRegex(ValueError, "build 3"):
            github_release.needs_release("0.3.1", 3, records, lambda tag: appcast(3))

    def test_older_marketing_version_cannot_become_latest(self):
        with self.assertRaisesRegex(ValueError, "v0.4.0"):
            github_release.needs_release("0.3.1", 5, [release("0.4.0")], lambda tag: appcast(4))

    def test_missing_build_in_published_feed_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "v0.2.0"):
            github_release.needs_release("0.3.1", 4, [release("0.2.0")], lambda tag: appcast(""))

    @patch.object(github_release, "gh")
    @patch.object(github_release, "tag_commit")
    def test_publisher_refuses_a_tag_pointing_at_a_different_commit(self, tag_commit, gh):
        tag_commit.return_value = "different"
        with self.assertRaisesRegex(ValueError, "different commit"):
            github_release.publish("example/remora", "0.3.1", 4, "expected", [], ["dmg", "appcast"])
        gh.assert_not_called()

    @patch.object(github_release, "gh")
    @patch.object(github_release, "tag_commit")
    @patch.object(github_release, "release_records")
    def test_partial_draft_upload_is_retried_before_publication(self, records, tag_commit, gh):
        tag_commit.return_value = None
        gh.return_value = "expected"
        records.return_value = [automated_draft("dmg", "appcast")]
        github_release.publish("example/remora", "0.3.1", 4, "expected", [automated_draft("dmg")], ["dmg", "appcast"])
        gh.assert_any_call("release", "upload", "v0.3.1", "dmg", "appcast", "--clobber", "--repo", "example/remora")
        gh.assert_called_with(
            "api", "--method", "PATCH", "repos/example/remora/releases/123",
            "-f", "target_commitish=expected", "-F", "draft=false", "-f", "make_latest=true",
        )

    @patch.object(github_release, "gh")
    @patch.object(github_release, "tag_commit")
    @patch.object(github_release, "release_records")
    def test_main_advancing_mid_upload_leaves_release_as_a_draft(self, records, tag_commit, gh):
        tag_commit.return_value = None
        records.return_value = [automated_draft("dmg", "appcast")]
        gh.side_effect = ["expected", "", "newer"]
        with self.assertRaisesRegex(ValueError, "Main advanced"):
            github_release.publish("example/remora", "0.3.1", 4, "expected", [], ["dmg", "appcast"])
        release_calls = [call.args for call in gh.call_args_list if call.args[0] == "release"]
        self.assertEqual(len(release_calls), 1)
        self.assertIn("--draft", release_calls[0])

    @patch.object(github_release, "gh")
    @patch.object(github_release, "tag_commit")
    def test_manual_draft_is_never_replaced(self, tag_commit, gh):
        tag_commit.return_value = None
        gh.return_value = "expected"
        draft = dict(automated_draft(), author={"login": "maintainer"})
        with self.assertRaisesRegex(ValueError, "Review the existing draft"):
            github_release.publish("example/remora", "0.3.1", 4, "expected", [draft], ["dmg", "appcast"])
        gh.assert_not_called()

    @patch.object(github_release, "gh")
    @patch.object(github_release, "tag_commit")
    @patch.object(github_release, "release_records")
    def test_release_published_during_upload_is_left_untouched(self, records, tag_commit, gh):
        tag_commit.return_value = None
        records.return_value = [release("0.3.1", prerelease=True)]
        gh.return_value = "expected"
        github_release.publish("example/remora", "0.3.1", 4, "expected", [], ["dmg", "appcast"])
        self.assertEqual(gh.call_count, 2)
        self.assertIn("--draft", gh.call_args.args)


if __name__ == "__main__":
    unittest.main()
