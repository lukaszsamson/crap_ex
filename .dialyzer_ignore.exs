[
  # The Credo complexity backend is opt-in and `:credo` is an optional dep
  # (runtime: false), so Dialyzer's PLT does not always contain it. The call is
  # guarded at runtime by `ensure_credo!/0`.
  {"lib/crap_ex/complexity/credo.ex", :unknown_function}
]
