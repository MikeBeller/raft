defmodule Raft.Server do
  use GenStateMachine, callback_mode: :state_functions
  require Logger
  #states: [:follower, :leader, :candidate]

  @election_timeout_min 150
  @election_timeout_max 300

  defmodule Data do
    defstruct [
      current_term: 0,
      voted_for: nil,
      log: [],
      commit_index: 0,
      last_applied: 0,
      next_index: %{},
      match_index: %{},
      timer: nil,
      last_event_time: 0,
    ]
  end

  defp election_timeout() do
    diff = @election_timeout_max - @election_timeout_min
    @election_timeout_min - 1 + :rand.uniform(diff + 1)
  end

  defp start_election_timer(%Data{timer: timer} = data, timeout \\ election_timeout()) do
    if timer do
      _ = Process.cancel_timer(timer)
    end

    new_timer = Process.send_after(self(), :election_timeout, timeout)
    %{data | timer: new_timer}
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenStateMachine.start_link(__MODULE__, {:follower, %Data{}}, name: name)
  end

  def init({state, data} \\ {:follower, %Data{}}) do
    data = start_election_timer(data)
    {:ok, state, data}
  end

  def follower(:info, :timeout, %Data{timer: timer} = data) do
    Logger.debug "Election timer ended"
    {:keep_state, %{data | timer: timer}}
  end
end
