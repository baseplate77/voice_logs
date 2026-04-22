.PHONY: analyze test fmt check codegen clean

# Full static analysis per CLAUDE.md: treat infos as fatal and fail on any
# unformatted source. Scoped to lib/ + test/ so vendored sources under
# build/ and generated .dart_tool/ contents are left alone. CI runs this
# before tests.
analyze:
	dart analyze --fatal-infos
	dart format --set-exit-if-changed lib test

test:
	flutter test

# Run codegen for drift, freezed, json_serializable. Not run automatically
# — call after schema or data-class changes.
codegen:
	dart run build_runner build --delete-conflicting-outputs

fmt:
	dart format lib test

# Convenience: analyze + test together.
check: analyze test

clean:
	flutter clean
