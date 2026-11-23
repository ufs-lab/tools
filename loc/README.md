# loc

`loc.sh` counts the lines of the files in one or more directories, by category, and prints the counts as JSON.

```bash
loc/loc.sh src tests
```

```json
{
  "directories": [
    {"path": "src", "files": 12, "binary_files": 1, "lines": {"code": 840, "comments": 96, "tests": 0, "docs": 0, "generated": 0, "other": 14, "unknown": 0, "blank": 120}},
    {"path": "tests", "files": 5, "binary_files": 0, "lines": {"code": 0, "comments": 0, "tests": 410, "docs": 0, "generated": 0, "other": 0, "unknown": 0, "blank": 52}}
  ],
  "total": {"files": 17, "binary_files": 1, "lines": {"code": 840, "comments": 96, "tests": 410, "docs": 0, "generated": 0, "other": 14, "unknown": 0, "blank": 172}}
}
```

The numbers above are an example of the format.

## Categories

| Key | What it counts |
| --- | --- |
| `code` | Non-blank lines of source files that are not comments. |
| `comments` | Comment lines of source files. |
| `tests` | Non-blank lines of test files and fixtures. |
| `docs` | Non-blank lines of documentation, such as Markdown. |
| `generated` | Non-blank lines of lockfiles. |
| `other` | Non-blank lines of config and text assets. |
| `unknown` | Non-blank lines of files whose type the tool does not know. |
| `blank` | Blank lines of all text files. |

`files` is the number of text files read.
`binary_files` is the number of binary files and archives; their lines are not counted.

## How it counts

- The path decides the category of a file: test names and source extensions first, then test, fixture and documentation directories.
- A file with no known extension is a script when its first line is a shebang or a ShellCheck `shell=` directive.
- The tool reads each file whole, so it knows when a line is in a block comment, a string that spans lines or a heredoc.
- Comment syntax is per language: the C family, shell, Python, Ruby, Perl, SQL, Lua, Terraform and Vue.
- A file that holds a NUL byte is a binary file.
- A symbolic link is not read.

## Which files

- In a Git work tree, the tool reads the tracked files and the untracked files that `.gitignore` does not leave out.
  It classifies each path from the top of the work tree, so `loc.sh tests/unit` still counts tests.
- In any other directory, the tool reads every regular file, and classifies each path from that directory.
- `total` is the sum of the directories.
  When one directory holds another, the files of the inner directory count twice.

## Exit status

The tool exits 2, names the fault on standard error and prints no JSON when it gets no argument, or an argument that is not a directory.

## Requirements

Bash, Git and `awk`.

## Tests

```bash
for suite in loc/tests/test_*.sh; do bash "$suite"; done
```
