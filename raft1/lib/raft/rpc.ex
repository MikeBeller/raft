defmodule Raft.RPC.RequestVoteReq do
  defstruct [:term, :from, :last_log_index, :last_log_term]

  @type t :: %__MODULE__{
    term: non_neg_integer(),
    from: atom(),
    last_log_index: non_neg_integer(),
    last_log_term: non_neg_integer(),
  }

  @spec new(non_neg_integer(), atom(), non_neg_integer(), non_neg_integer()) :: t
  def new(term, from, last_log_index, last_log_term) do
    %__MODULE__{term: term, from: from, last_log_index: last_log_index, last_log_term: last_log_term}
  end
end
