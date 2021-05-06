# raft

Implementation of the Raft consensus protocol in Elixir.

NOTE as of now, this is for pedagogical purposes and my own explorations
of Raft and Elixir.  Not intended for production use!

## References

Helpful references and sources of inspiration:

* [Raft site and paper](https://raft.github.io/)
* [Erlang implementation of Raft](https://github.com/rabbitmq/ra)
* [Elixir implementation of Raft](https://github.com/toniqsystems/raft)

## Architecture

The core consensus module, `Raft.Consensus` is a purely functional module which
implements the consensus state machine computations.  Events (receipt of messages
or timer expiries) are represented by calls to the Consensus.ev function,
which takes the current consensus state and the received event and returns
a new consensus state, and a list of "actions" (side effects) which are
either message sends or timer settings / cancellations.

This general approach was inspired by Sasa Juric's article:
[To Spawn or Not to Spawn](https://www.theerlangelist.com/article/spawn_or_not)
which makes the case that it makes it easy to test the raft consensus
implementation without any temporal concerns.  E.g. no test latency, send/receive etc.

To see this in action, have a look at test/raft_consensus_test.exs.  I have
implemented `event`/`expect` functions and the `match` macro which, when
combined with the pipe operator, make almost a sort of DSL for easily
expressing tests of the Raft.Consensus module.

To "bring the system to life" we add a very simple GenServer called
`Raft.Server`, whose job is to redirect received events to the consensus
module whose state it manages, and also manage timers.  It includes
features for logging communications between itself and the other servers
in the cluster, and even includes/will include "drop" functionality for simulation
of broken connections during testing.

## Status

* Basic Raft.Consensus module working, implemented per the paper, with tests of
  the main path.  Still needs many tests for edge cases presumably.
* First cut at Raft.Server is there, but so far just syncs up and exchanges
  the initial :noop message.  Well..that's something.

