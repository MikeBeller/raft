# raft

RAFT consensus protocol in Elixir.

NOTE as of now, this is for pedagogical purposes and my own explorations
of RAFT and Elixir.  Not intended for production use!

## References

In working on this project I made use of / reference to the following:

* [Raft site and paper](https://raft.github.io/)
* [Erlang implementation of Raft](https://github.com/rabbitmq/ra)
* [Elixir implementation of Raft](https://github.com/toniqsystems/raft)

## Architecture

The core consensus module (Consensus.ex) is a purely functional library which
implements the consensus state machine computations themselves, without any
processes.  

The approach was inspired by Sasa Juric's article:
[To Spawn or Not to Spawn](https://www.theerlangelist.com/article/spawn_or_not)

This makes it easy to test the raft implementation without any temporal
concerns.  E.g. no test latency, send/receive etc.

With a working consensus module, we then add Raft.Server, which just
embeds a Consensus module, and manages sends/receives/timers.

## Cool stuff

Note also the "event/expect" functions/macros in Raft.ConsensusTest,
which make it very easy to write and read the tests.

