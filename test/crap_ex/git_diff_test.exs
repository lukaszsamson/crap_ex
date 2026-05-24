defmodule CrapEx.GitDiffTest do
  use ExUnit.Case, async: true

  alias CrapEx.GitDiff

  describe "parse/1" do
    test "extracts new-file line ranges per file" do
      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      index 111..222 100644
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -10,0 +11,3 @@ def foo do
      +  added
      +  added
      +  added
      @@ -20,1 +24,1 @@
      +  changed
      """

      assert GitDiff.parse(diff) == %{"lib/foo.ex" => [11..13, 24..24]}
    end

    test "ignores pure deletions (new count 0)" do
      diff = """
      --- a/lib/bar.ex
      +++ b/lib/bar.ex
      @@ -5,3 +4,0 @@
      """

      assert GitDiff.parse(diff) == %{"lib/bar.ex" => []}
    end

    test "single-line hunk without comma length" do
      diff = """
      --- a/a.ex
      +++ b/a.ex
      @@ -1 +1 @@
      +x
      """

      assert GitDiff.parse(diff) == %{"a.ex" => [1..1]}
    end
  end
end
