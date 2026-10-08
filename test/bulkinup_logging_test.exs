defmodule BulkinupLoggingTest do
  # `async: false`, since the logger level is global and is lowered to `:debug` for these tests
  use BulkinupDemo.DataCase, async: false

  alias BulkinupDemo.Blog.Author

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  test "does not log skipped or recovered rows" do
    attrs_list = [%{id: 1}, %{id: 2, name: "valid", phone_number: "INVALID"}]

    {result, log} =
      ExUnit.CaptureLog.with_log([level: :debug], fn ->
        Bulkinup.upsert(Repo, Author, attrs_list,
          recover_changeset_errors: %{Author => %{phone_number: "555-1234"}}
        )
      end)

    assert {:ok, %{upserted: 1, skipped: 1}} = result

    # Sanity check: Ecto's `:debug` query logs have been captured
    assert log =~ "QUERY"

    # Only Ecto's own query and transaction logs remain
    for line <- String.split(log, "\n", trim: true), line =~ ~r/\[(debug|info|warning|error)\]/ do
      assert line =~ ~r/QUERY|begin|commit/
    end
  end
end
