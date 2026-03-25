"""Starlark codegen unit tests — aggregator."""

load("//tests:suite.bzl", _test_suite = "test_suite")
load("//tests/starlark/private:bazel.bzl", bazel_TESTS = "TEST_SUITE_TESTS")
load("//tests/starlark/private:expr.bzl", expr_TESTS = "TEST_SUITE_TESTS")
load("//tests/starlark/private:fn.bzl", fn_TESTS = "TEST_SUITE_TESTS")
load("//tests/starlark/private:gen.bzl", gen_TESTS = "TEST_SUITE_TESTS")
load("//tests/starlark/private:helpers.bzl", helpers_TESTS = "TEST_SUITE_TESTS")
load("//tests/starlark/private:stmt.bzl", stmt_TESTS = "TEST_SUITE_TESTS")

TEST_SUITE_NAME = "starlark"

TEST_SUITE_TESTS = {}
TEST_SUITE_TESTS.update(bazel_TESTS)
TEST_SUITE_TESTS.update(expr_TESTS)
TEST_SUITE_TESTS.update(fn_TESTS)
TEST_SUITE_TESTS.update(gen_TESTS)
TEST_SUITE_TESTS.update(helpers_TESTS)
TEST_SUITE_TESTS.update(stmt_TESTS)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
