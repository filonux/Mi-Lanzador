#!/usr/bin/env python3
import ast
import pathlib
from hashlib import sha256

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _top_level_tests(path):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    return [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name.startswith("test_")]


def test_no_duplicate_test_function_names_or_bodies():
    names = []
    bodies = {}
    for path in sorted((ROOT / "tests").glob("test_*.py")):
        for node in _top_level_tests(path):
            key = f"{path.name}:{node.name}"
            names.append(key)
            body = ast.dump(ast.Module(body=node.body, type_ignores=[]), include_attributes=False)
            digest = sha256(body.encode()).hexdigest()
            bodies.setdefault(digest, []).append(key)
    assert len(names) == len(set(names)), "duplicate test names"
    duplicates = {k: v for k, v in bodies.items() if len(v) > 1}
    assert not duplicates, duplicates


def test_full_simulation_exercises_are_pytest_discoverable():
    path = ROOT / "tests/test_full_simulation.py"
    text = path.read_text(encoding="utf-8")
    tree = ast.parse(text)
    exercises = {n.name for n in tree.body if isinstance(n, ast.FunctionDef) and n.name.startswith("exercise_")}
    wrappers = {n.name for n in tree.body if isinstance(n, ast.FunctionDef) and n.name.startswith("test_full_")}
    expected = {"test_full_" + name.removeprefix("exercise_") for name in exercises}
    assert wrappers == expected, (sorted(exercises), sorted(wrappers))


def test_test_project_runner_is_cache_free_and_bytecode_free():
    text = (ROOT / "tests/test_project.sh").read_text(encoding="utf-8")
    assert "-p no:cacheprovider" in text
    assert "PYTHONDONTWRITEBYTECODE=1" in text


def test_repo_root_has_no_pytest_ini():
    assert not (ROOT / "pytest.ini").exists()


def test_real_gtk_marker_is_registered_without_an_ini_file(pytestconfig):
    names = [line.split(":", 1)[0].strip() for line in pytestconfig.getini("markers")]
    assert "real_gtk" in names
