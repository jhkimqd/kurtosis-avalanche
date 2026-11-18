"""Load the package's Starlark modules in Python.

The modules stay within the syntax that Starlark and Python share, so `exec`
can run their logic: parsing, validation, sizing, and plan construction against
a fake `plan`. scripts/check-package.sh covers the real Kurtosis interpreter.
"""

import ast
import builtins
import json
import os
import pathlib
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[1]

_TYPE_NAMES = {
    bool: "bool",
    int: "int",
    str: "string",
    dict: "dict",
    list: "list",
    tuple: "tuple",
    type(None): "NoneType",
}


class Fail(Exception):
    """Raised by the Starlark builtin `fail`."""


def _fail(message):
    raise Fail(message)


# Python syntax that Starlark does not have. A module that uses it would pass
# these tests and then fail in Kurtosis.
_PYTHON_ONLY = (
    ast.While, ast.Try, ast.ClassDef, ast.JoinedStr, ast.With, ast.Import,
    ast.ImportFrom, ast.Global, ast.Nonlocal, ast.Yield, ast.Raise, ast.Assert,
    ast.Delete, ast.NamedExpr, ast.Is, ast.IsNot, ast.Set, ast.SetComp,
    ast.AsyncFunctionDef, ast.Await, ast.GeneratorExp, ast.Pow, ast.Starred,
    ast.AnnAssign, ast.MatMult,
)


def _is_python_only(node):
    if isinstance(node, _PYTHON_ONLY):
        return True
    # Starlark has no chained comparison (`a < b < c`) and no annotations.
    if isinstance(node, ast.Compare) and len(node.ops) > 1:
        return True
    if isinstance(node, ast.FunctionDef) and node.returns:
        return True
    return isinstance(node, ast.arg) and node.annotation is not None


def import_yaml():
    """Returns PyYAML, or None when it is not installed.

    The tests that read YAML skip without it. In CI a skipped test would hide
    a failure, so a missing PyYAML is an error there.
    """
    try:
        import yaml
    except ImportError:
        if os.environ.get("CI"):
            raise
        return None
    return yaml


def _record(kind):
    """Stands in for a Kurtosis type such as ServiceConfig: keeps its arguments."""
    return lambda **kwargs: SimpleNamespace(kind=kind, **kwargs)


_BUILTINS = {
    "fail": _fail,
    "type": lambda value: _TYPE_NAMES.get(builtins.type(value), "unknown"),
    "struct": lambda **kwargs: SimpleNamespace(**kwargs),
    "json": SimpleNamespace(encode=json.dumps, decode=json.loads),
}
for _kind in (
    "ServiceConfig",
    "PortSpec",
    "Directory",
    "ExecRecipe",
    "PostHttpRequestRecipe",
    "ImageBuildSpec",
    "User",
):
    _BUILTINS[_kind] = _record(_kind)

_modules = {}


def load(path):
    """Returns the module at `path` (relative to the repository root)."""
    file = (ROOT / path).resolve()
    if file not in _modules:
        namespace = dict(_BUILTINS)
        namespace["import_module"] = lambda relative: load(
            (file.parent / relative).resolve().relative_to(ROOT)
        )
        tree = ast.parse(file.read_text(), str(file))
        for node in ast.walk(tree):
            if _is_python_only(node):
                raise SyntaxError(
                    "{}:{}: {} is not Starlark".format(path, node.lineno, type(node).__name__)
                )
        exec(compile(tree, str(file), "exec"), namespace)
        _modules[file] = SimpleNamespace(**namespace)
    return _modules[file]


class FakePlan:
    """Records every plan instruction and returns predictable results."""

    def __init__(self):
        self.calls = []

    def _call(self, instruction, kwargs):
        self.calls.append((instruction, kwargs))

    def upload_files(self, **kwargs):
        self._call("upload_files", kwargs)
        return kwargs["name"]

    def render_templates(self, **kwargs):
        self._call("render_templates", kwargs)
        return kwargs["name"]

    def store_service_files(self, **kwargs):
        self._call("store_service_files", kwargs)
        return kwargs["name"]

    def add_service(self, **kwargs):
        self._call("add_service", kwargs)
        return SimpleNamespace(name=kwargs["name"], ip_address="ip-of-" + kwargs["name"])

    def remove_service(self, **kwargs):
        self._call("remove_service", kwargs)

    def wait(self, **kwargs):
        self._call("wait", kwargs)

    def exec(self, **kwargs):
        self._call("exec", kwargs)
        # An extracted value becomes "<name>" so that tests can follow it.
        extract = getattr(kwargs["recipe"], "extract", {})
        return {"extract." + name: "<{}>".format(name) for name in extract}

    def commands(self):
        """Returns the command of every `plan.exec`, in order."""
        return [kwargs["recipe"].command for name, kwargs in self.calls if name == "exec"]

    def services(self):
        """Returns every started service as {name: ServiceConfig}."""
        return {
            kwargs["name"]: kwargs["config"]
            for name, kwargs in self.calls
            if name == "add_service"
        }

    def rendered(self, artifact):
        """Returns the JSON files of a rendered artifact as {path: content}."""
        for name, kwargs in self.calls:
            if name == "render_templates" and kwargs["name"] == artifact:
                return {
                    path: json.loads(template.data["content"])
                    for path, template in kwargs["config"].items()
                }
        raise KeyError(artifact)
