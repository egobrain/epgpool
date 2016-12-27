[![Build Status](https://travis-ci.org/egobrain/epgpool.png?branch=master)](https://travis-ci.org/egobrain/epgpool)
[![Coveralls](https://img.shields.io/coveralls/egobrain/epgpool.svg)](https://coveralls.io/github/egobrain/epgpool)
[![GitHub tag](https://img.shields.io/github/tag/egobrain/epgpool.svg)](https://github.com/egobrain/epgpool)
[![Hex.pm](https://img.shields.io/hexpm/v/epgpool.svg)](https://hex.pm/packages/epgpool)

# epgpool: erlang postgresql pool.
----------------------------------------------------

## Description ##

Erlang postgresql pool application based on poolboy and epgsql

## Example

test.config

```erlang
[
 {epgpool, [
  {database_host, "localhost"},
  {database_name, "mydb"},
  {database_user, "test_user"},
  {database_password, "passwd"}
 ]}
]
```

```erlang
epgpool:with(fun(C) ->
    {ok, _Columns, [{A}]} = epgpool:squery(C, "select 1"),
    {ok, _Columns, [{A}]} = epgpool:squery(C, "select 2")
end)
```
