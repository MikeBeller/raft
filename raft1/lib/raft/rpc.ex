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

  @type t :: RequestVoteReq.t | RequestVoteResp.t
end
