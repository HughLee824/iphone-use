import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "check_docs", Path(__file__).resolve().parents[1] / "checks/check-docs.py")
docs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(docs)


class DocumentationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.files = set()

    def write(self, name, content, public=True):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        if public:
            self.files.add(path)
        return path

    def test_relative_links_anchors_images_and_directory(self):
        self.write("README.md", "[Guide](docs/guide.md#输入-ax) ![Image](assets/view.svg) [Docs](docs)")
        self.write("docs/guide.md", "# 输入 `AX`\n[Home](../README.md)\n[Same](#输入-ax)")
        self.write("assets/view.svg", "<svg/>")
        self.assertEqual(docs.check(self.root, self.files), [])

    def test_missing_file_and_missing_anchor_report_source_line(self):
        self.write("README.md", "# Intro\n[Gone](docs/removed.md)\n[Heading](#gone)")
        errors = docs.check(self.root, self.files)
        self.assertEqual(len(errors), 2)
        self.assertIn("README.md:2: missing or non-public target", errors[0])
        self.assertIn("README.md:3: missing heading", errors[1])

    def test_existing_private_file_cannot_satisfy_public_link(self):
        self.write("README.md", "[Private](.local/evidence.md)")
        self.write(".local/evidence.md", "# Evidence", public=False)
        self.assertIn("non-public", docs.check(self.root, self.files)[0])

    def test_parent_directory_outside_repository_is_rejected(self):
        self.write("README.md", "[Outside](..)")
        self.assertIn("outside repository", docs.check(self.root, self.files)[0])

    def test_code_examples_and_remote_urls_are_ignored(self):
        self.write("README.md", """# Example
```md
[Code](missing.md)
```
~~~md
[Also code](missing.md)
~~~
`[Inline](missing.md)`
[Remote](https://example.com/page#unknown)
[Email](mailto:example@example.com)
""")
        self.assertEqual(docs.check(self.root, self.files), [])

    def test_unicode_duplicate_headings_and_explicit_id(self):
        self.write("README.md", """# 输入：`AX` **路径**
## 输入：AX 路径
<a id="manual"></a>
[One](#输入ax-路径) [Two](#输入ax-路径-1) [ID](#manual)
""")
        self.assertEqual(docs.check(self.root, self.files), [])

    def test_reference_definitions_encoded_paths_and_html_resources(self):
        self.write("README.md", """[Guide][g]
[g]: <docs/with space.md#标题>
[Encoded](docs/with%20space.md#%E6%A0%87%E9%A2%98)
<picture><source srcset="assets/view.svg"><img src="missing.svg"></picture>
""")
        self.write("docs/with space.md", "# 标题")
        self.write("assets/view.svg", "<svg/>")
        errors = docs.check(self.root, self.files)
        self.assertEqual(len(errors), 1)
        self.assertIn("missing.svg", errors[0])

    def test_git_inventory_includes_new_files_but_not_deleted_or_ignored(self):
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        tracked = self.write("old.md", "# Old")
        self.write(".gitignore", ".local/\n")
        subprocess.run(["git", "-C", str(self.root), "add", "old.md", ".gitignore"], check=True)
        tracked.unlink()
        fresh = self.write("docs/new.md", "# New")
        self.write(".local/private.md", "# Private", public=False)
        self.assertEqual(docs.public_files(self.root), {self.root / ".gitignore", fresh})


if __name__ == "__main__":
    unittest.main()
