defmodule Raft.LogTest do
  use ExUnit.Case, async: true
  alias Raft.Log

  test "new log" do
    log = Log.new()
    assert 0 == Log.last_index(log)
    assert 0 == Log.last_term(log)
  end

  test "append" do
    log = Log.new() |> Log.append(1, :noop, nil)
    assert 1 == Log.last_index(log)
    assert 1 == Log.last_term(log)

    log = Log.append(log, 1, :cmd, :hello)
    assert 2 == Log.last_index(log)
    assert 1 == Log.last_term(log)
  end

  test "get entry" do
    log = Log.new()
    assert {:error, :not_found} = Log.get_entry(log, 7)

    log = log
          |> Log.append(1, :noop, nil)
          |> Log.append(1, :cmd, nil)
          |> Log.append(2, :cmd, 3)

    assert {:ok, %Log.Entry{type: :noop}} = Log.get_entry(log, 1)
    assert {:ok, %Log.Entry{type: :cmd}} = Log.get_entry(log, 2)
    assert {:ok, %Log.Entry{term: 2}} = Log.get_entry(log, 3)
  end
end
