defmodule BulkinupConcurrencyTest do
  # `async: false` puts the SQL sandbox in shared mode, so the tasks spawned by
  # `:max_concurrency` may use the test's database connection
  use BulkinupDemo.DataCase, async: false

  alias BulkinupDemo.Blog.Author

  test "upserts chunks concurrently, each in its own transaction" do
    attrs_list = Enum.map(1..5, fn id -> %{id: id, name: "author-#{id}"} end)

    {:ok, %{upserted: 5, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_list, chunk_size: 2, max_concurrency: 2)

    assert Repo.all(from a in Author, order_by: a.id, select: a.name) ==
             Enum.map(1..5, &"author-#{&1}")
  end

  test "inserts chunks concurrently, each in its own transaction" do
    attrs_list = Enum.map(1..5, fn id -> %{id: id, name: "author-#{id}"} end)

    {:ok, %{inserted: 5, skipped: 0}} =
      Bulkinup.insert(Repo, Author, attrs_list, chunk_size: 2, max_concurrency: 2)

    assert Repo.aggregate(Author, :count) == 5
  end

  test "composes with a Stream as attrs input" do
    attrs_stream = Stream.map(1..5, fn id -> %{id: id, name: "author-#{id}"} end)

    {:ok, %{upserted: 5, skipped: 0}} =
      Bulkinup.upsert(Repo, Author, attrs_stream, chunk_size: 2, max_concurrency: 2)

    assert Repo.aggregate(Author, :count) == 5
  end

  test "calls on_skipped from each concurrent chunk that has skipped rows" do
    test_pid = self()
    attrs_list = [%{id: 1, name: "a"}, %{id: 2}, %{id: 3, name: "c"}, %{id: 4}]

    {:ok, %{upserted: 2, skipped: 2}} =
      Bulkinup.upsert(Repo, Author, attrs_list,
        chunk_size: 1,
        max_concurrency: 2,
        on_skipped: &send(test_pid, {:skipped, &1})
      )

    assert_received {:skipped, %{changesets: [first_changeset]}}
    assert_received {:skipped, %{changesets: [second_changeset]}}
    refute_received {:skipped, _}

    assert Enum.sort([first_changeset.changes.id, second_changeset.changes.id]) == [2, 4]
  end

  @tag :capture_log
  test "keeps committed chunks when a later chunk fails" do
    # With max_concurrency: 1 the chunks run in order, one transaction each: Alice's chunk
    # commits before Bob's post fails its foreign key constraint
    attrs_list = [
      %{id: 1, name: "Alice"},
      %{id: 2, name: "Bob", posts: [%{id: 101, author_id: 999, title: "a"}]}
    ]

    assert_raise Postgrex.Error, ~r/foreign_key/, fn ->
      Bulkinup.upsert(Repo, Author, attrs_list, chunk_size: 1, max_concurrency: 1)
    end

    # Unlike the default single-transaction mode, the committed chunk is not rolled back
    assert Repo.all(from a in Author, select: a.name) == ["Alice"]
  end
end
