defmodule Raft.RPC do
  defmodule RequestVoteReq do
    defstruct [:from, :term, :last_log_index, :last_log_term]

    @type t :: %__MODULE__{
      from: Raft.addr(),
      term: non_neg_integer(),
      last_log_index: non_neg_integer(),
      last_log_term: non_neg_integer(),
    }
  end

  defmodule RequestVoteResp do
    defstruct [:from, :term, :granted]

    @type t :: %__MODULE__ {
      from: Raft.addr(),
      term: non_neg_integer(),
      granted: boolean(),
    }
  end

  defmodule AppendEntriesReq do
    defstruct [:from, :term, :prev_log_index, :prev_log_term, :entries, :leader_commit]

    @type t :: %__MODULE__ {
      from: Raft.addr(),
      term: non_neg_integer(),
      prev_log_index: non_neg_integer(),
      prev_log_term: non_neg_integer(),
      entries: list(Raft.Log.Entry.t),
      leader_commit: non_neg_integer(),
    }
  end

  defmodule AppendEntriesResp do
    defstruct [:from, :term, :success]

    @type t :: %__MODULE__ {
      from: Raft.addr(),
      term: non_neg_integer(),
      success: boolean(),
    }
  end

  defmodule WriteReq do
    defstruct [:from, :id, :command]

    @type t :: %__MODULE__ {
      from: Raft.addr(),
      id: any(),
      command: any(),
    }
  end

  defmodule WriteResp do
    defstruct [:from, :id, :result, :leader]

    @type t :: %__MODULE__ {
      from: Raft.addr(),
      id: any(),
      result: :ok | :error,
      leader: nil | Raft.addr(),
    }
  end

  @type t :: RequestVoteReq.t | RequestVoteResp.t | AppendEntriesReq.t | AppendEntriesResp.t
end
