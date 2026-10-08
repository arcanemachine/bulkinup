defmodule BulkinupInsertTest do
  use BulkinupDemo.DataCase, async: true

  alias BulkinupDemo.Blog.{Author, Comment, Post, Profile, Tag}

  test "inserts parents with their nested associations and embeds" do
    attrs_list = [
      %{
        id: 1,
        name: "Alice",
        posts: [
          %{
            id: 101,
            author_id: 1,
            title: "a",
            comments: [%{id: 1001, post_id: 101, body: "nice"}],
            tags: [%{id: 11, name: "elixir"}]
          }
        ],
        profile: %{id: 1, author_id: 1, bio: "author of a"},
        address: %{street: "123 Main St", city: "Springfield"},
        social_links: [%{label: "blog", url: "https://example.com"}]
      }
    ]

    {:ok, %{inserted: 1, skipped: 0}} = Bulkinup.insert(Repo, Author, attrs_list)

    author = Repo.get!(Author, 1)
    assert author.address.city == "Springfield"
    assert [%{label: "blog"}] = author.social_links
    assert Repo.get!(Post, 101).title == "a"
    assert Repo.get!(Comment, 1001).body == "nice"
    assert Repo.get!(Profile, 1).bio == "author of a"
    assert Repo.get!(Tag, 11).name == "elixir"
    assert Repo.aggregate("posts_tags", :count) == 1
  end

  test "raises on a duplicate parent and persists nothing" do
    {:ok, _} = Bulkinup.insert(Repo, Author, [%{id: 1, name: "Alice"}])

    # With chunk_size: 1, Bob's chunk is written before the duplicate raises. The default
    # single transaction rolls it back
    assert_raise Postgrex.Error, ~r/unique/, fn ->
      Bulkinup.insert(Repo, Author, [%{id: 2, name: "Bob"}, %{id: 1, name: "Alice again"}],
        chunk_size: 1
      )
    end

    assert Repo.all(from a in Author, select: a.name) == ["Alice"]
  end

  test "raises on a pre-existing many_to_many child by default" do
    {:ok, _} = Bulkinup.insert(Repo, Author, [%{id: 1, name: "Alice"}])
    {:ok, _} = Bulkinup.insert(Repo, Tag, [%{id: 11, name: "elixir"}])

    attrs_list = [%{id: 101, author_id: 1, title: "a", tags: [%{id: 11, name: "elixir"}]}]

    assert_raise Postgrex.Error, ~r/unique/, fn ->
      Bulkinup.insert(Repo, Post, attrs_list)
    end

    assert Repo.aggregate(Post, :count) == 0
  end

  test "inserts alongside pre-existing many_to_many children with the insert_all_opts recipe" do
    {:ok, _} = Bulkinup.insert(Repo, Author, [%{id: 1, name: "Alice"}])
    {:ok, _} = Bulkinup.insert(Repo, Tag, [%{id: 11, name: "elixir"}])

    attrs_list = [%{id: 101, author_id: 1, title: "a", tags: [%{id: 11, name: "elixir"}]}]

    {:ok, %{inserted: 1, skipped: 0}} =
      Bulkinup.insert(Repo, Post, attrs_list,
        insert_all_opts: %{
          Tag => [on_conflict: :nothing],
          "posts_tags" => [on_conflict: :nothing]
        }
      )

    assert Repo.get!(Post, 101).title == "a"
    assert Repo.aggregate("posts_tags", :count) == 1
  end

  test "raises on the upsert-only replace_all_except option" do
    assert_raise ArgumentError, ~r/only apply to an upsert/, fn ->
      Bulkinup.insert(Repo, Author, [%{id: 1, name: "Alice"}], replace_all_except: [:name])
    end
  end

  test "returns inserted and skipped counts, and reports skipped rows to on_skipped" do
    test_pid = self()
    attrs_list = [%{id: 1, name: "Alice"}, %{id: 2}]

    assert {:ok, %{inserted: 1, skipped: 1}} =
             Bulkinup.insert(Repo, Author, attrs_list,
               on_skipped: &send(test_pid, {:skipped, &1})
             )

    assert_received {:skipped, %{verb: :insert, schema_module: Author, changesets: [changeset]}}
    assert changeset.changes.id == 2
  end

  test "composes with a Stream as attrs input" do
    attrs_stream = Stream.map(1..5, fn id -> %{id: id, name: "author-#{id}"} end)

    {:ok, %{inserted: 5, skipped: 0}} = Bulkinup.insert(Repo, Author, attrs_stream, chunk_size: 2)

    assert Repo.aggregate(Author, :count) == 5
  end
end
