defmodule Convex.Director do

  #===========================================================================
  # Behaviour Definition
  #===========================================================================

  @callback perform(Ctx.t, Ctx.op, map)
    :: {:ok, Ctx.t} | {:error, reason :: term}


  #===========================================================================
  # Attributes
  #===========================================================================

  @operation_rx ~r/^(?:\*|[a-z][a-zA-Z0-9_]*(?:\.[a-z][a-zA-Z0-9_]*)*(?:\.\*)?)$/


  #===========================================================================
  # Macros
  #===========================================================================

  defmacro __using__(_opt) do
    Module.register_attribute(__CALLER__.module, :perform_functions, accumulate: true)
    Module.register_attribute(__CALLER__.module, :validate_functions, accumulate: true)
    quote do
      @beaviour Convex.Director

      import Kernel, except: [def: 2]
      import Convex.Director, only: [
        def: 2,
        delegate: 2,
        perform: 2,
        perform: 3,
        perform: 4,
        validate: 2,
        validate: 3,
        validate: 4,
      ]

      @before_compile Convex.Director
    end
  end


  defmacro def({:when, ctx1, [{:perform, ctx2, [_, _, _] = args}, when_ast]}, blocks) do
    call = {:when, ctx1, [{:_perform, ctx2, [_, _, _] = args}, when_ast]}
    do_ast = Keyword.fetch!(blocks, :do)
    ast = quote do
      defp unquote(call) do
        unquote(do_ast)
      end
    end
    Module.put_attribute(__CALLER__.module, :perform_functions, ast)
  end

  defmacro def({:perform, ctx, [_, _, _] = args}, blocks) do
    call = {:_perform, ctx, args}
    do_ast = Keyword.fetch!(blocks, :do)
    ast = quote do
      defp unquote(call) do
        unquote(do_ast)
      end
    end
    Module.put_attribute(__CALLER__.module, :perform_functions, ast)
  end

  defmacro def({:when, ctx1, [{:validate, ctx2, [_, _, _] = args}, when_ast]}, blocks) do
    call = {:when, ctx1, [{:_validate, ctx2, [_, _, _] = args}, when_ast]}
    do_ast = Keyword.fetch!(blocks, :do)
    ast = quote do
      defp unquote(call) do
        unquote(do_ast)
      end
    end
    Module.put_attribute(__CALLER__.module, :validate_functions, ast)
  end

  defmacro def({:validate, ctx, [_, _, _] = args}, blocks) do
    call = {:_validate, ctx, args}
    do_ast = Keyword.fetch!(blocks, :do)
    ast = quote do
      defp unquote(call) do
        unquote(do_ast)
      end
    end
    Module.put_attribute(__CALLER__.module, :validate_functions, ast)
  end

  defmacro def(call, blocks) do
    do_ast = Keyword.fetch!(blocks, :do)
    quote do
      def unquote(call) do
        unquote(do_ast)
      end
    end
  end


  defmacro delegate(op, mod) do
    generate_delegate(__CALLER__, op, mod)
  end


  defmacro perform(op, params_and_blocks) do
    {blocks, args} = Keyword.split(params_and_blocks, [:do, :else])
    do_ast = Keyword.fetch!(blocks, :do)
    ctx_var = Macro.var(:ctx, __MODULE__)
    generate_perform(__CALLER__, ctx_var, ctx_var, op, args, do_ast)
  end


  defmacro perform(op, args_or_ctx, params_and_blocks) do
    case Keyword.split(params_and_blocks, [:do, :else]) do
      {blocks, []} ->
        do_ast = Keyword.fetch!(blocks, :do)
        ctx_var = Macro.var(:ctx, __MODULE__)
        generate_perform(__CALLER__, ctx_var, ctx_var, op, args_or_ctx, do_ast)
      {blocks, args} ->
        do_ast = Keyword.fetch!(blocks, :do)
        ctx_var = Macro.var(:ctx, __MODULE__)
        ctx_ast = quote do: unquote(args_or_ctx) = unquote(ctx_var)
        generate_perform(__CALLER__, ctx_ast, ctx_var, op, args, do_ast)
    end
  end


  defmacro perform(op, ctx, args, blocks) do
    do_ast = Keyword.fetch!(blocks, :do)
    ctx_var = Macro.var(:ctx, __MODULE__)
    ctx_ast = quote do: unquote(ctx) = unquote(ctx_var)
    generate_perform(__CALLER__, ctx_ast, ctx_var, op, args, do_ast)
  end


  defmacro validate(op, params_and_blocks) do
    {blocks, args} = Keyword.split(params_and_blocks, [:do, :else])
    do_ast = Keyword.fetch!(blocks, :do)
    ctx_var = Macro.var(:ctx, __MODULE__)
    generate_validate(__CALLER__, ctx_var, ctx_var, op, args, do_ast)
  end


  defmacro validate(op, args_or_ctx, params_and_blocks) do
    case Keyword.split(params_and_blocks, [:do, :else]) do
      {blocks, []} ->
        do_ast = Keyword.fetch!(blocks, :do)
        ctx_var = Macro.var(:ctx, __MODULE__)
        generate_validate(__CALLER__, ctx_var, ctx_var, op, args_or_ctx, do_ast)
      {blocks, args} ->
        do_ast = Keyword.fetch!(blocks, :do)
        ctx_var = Macro.var(:ctx, __MODULE__)
        ctx_ast = quote do: unquote(args_or_ctx) = unquote(ctx_var)
        generate_validate(__CALLER__, ctx_ast, ctx_var, op, args, do_ast)
    end
  end


  defmacro validate(op, ctx, args, blocks) do
    do_ast = Keyword.fetch!(blocks, :do)
    ctx_var = Macro.var(:ctx, __MODULE__)
    ctx_ast = quote do: unquote(ctx) = unquote(ctx_var)
    generate_validate(__CALLER__, ctx_ast, ctx_var, op, args, do_ast)
  end


  defmacro __before_compile__(_env) do
    enforce? = true == Module.get_attribute(__CALLER__.module, :enforce_validation)
    perform_funs = Module.get_attribute(__CALLER__.module, :perform_functions)
      |> Enum.reverse()
    validate_funs = Module.get_attribute(__CALLER__.module, :validate_functions)
    |> Enum.reverse()

    pub_funs = if length(validate_funs) == 0 do
      [
        quote do
          def perform(ctx, op, args) do
            _perform(ctx, op, args)
          end
          def validate(ctx, op, args) do
            {:ok, args}
          end
        end
      ]
    else
      [
        quote do
          def perform(ctx, op, args) do
            case _validate(ctx, op, args) do
              {:ok, new_args} -> _perform(ctx, op, new_args)
              {:error, reason} ->
                Convex.Context.failed(ctx, reason)
            end
          end
          def validate(ctx, op, args) do
            try do
              _validate(ctx, op, args)
            rescue
              e -> {:error, Convex.Errors.reason(e)}
            end
          end
        end
      ]
    end
    perform_last = [
      quote do
        defp _perform(ctx, _op, _args), do: Convex.Errors.unknown_operation!(ctx)
      end
    ]
    validate_last = case {length(validate_funs) > 0, enforce?} do
      {true, true} -> [
        quote do
          defp _validate(ctx, _op, _args), do: Convex.Errors.unknown_operation!(ctx)
        end
      ]
      {true, false} -> [
        quote do
          defp _validate(_ctx, _op, args), do: {:ok, args}
        end
      ]
      {false, _} -> []
    end

    all = pub_funs ++ perform_funs ++ perform_last ++ validate_funs ++ validate_last
    quote do: (unquote_splicing(all))
  end


  #===========================================================================
  # Internal Functions
  #===========================================================================

  defp parse_operation(caller, op, default_var_name \\ :op)

  defp parse_operation(caller, {:=, _, [op, {name, _, ns} = var]}, _)
    when is_binary(op) and is_atom(name) and is_atom(ns) do
    {var, operation_to_ast(caller, op)}
  end

  defp parse_operation(caller, {:=, _, [{name, _, ns} = var, op]}, _)
    when is_binary(op) and  is_atom(name) and is_atom(ns) do
    {var, operation_to_ast(caller, op)}
  end

  defp parse_operation(caller, op, default_var_name)
    when is_binary(op) do
    var = Macro.var(default_var_name, __MODULE__)
    {var, operation_to_ast(caller, op)}
  end


  defp parse_args(caller, items) when is_list(items) do
    {:%{}, [line: caller.line], items}
  end

  defp parse_args(_, args), do: args


  defp generate_delegate(caller, op, mod) do
    {op_var, op_ast} = parse_operation(caller, op)
    ast = quote do
      defp _perform(ctx, unquote(op_ast) = unquote(op_var), args) do
        unquote(mod).perform(ctx, unquote(op_var), args)
      end
    end
    Module.put_attribute(caller.module, :perform_functions, ast)
  end


  defp generate_perform(caller, ctx_ast, ctx_var, op, args, do_ast) do
    args_ast = parse_args(caller, args)
    {op_var, op_ast} = parse_operation(caller, op, :_)
    body_ast = generate_perform_body(ctx_var, do_ast)
    ast = quote do
      defp _perform(unquote(ctx_ast), unquote(op_ast) = unquote(op_var), unquote(args_ast)) do
        unquote(body_ast)
      end
    end
    Module.put_attribute(caller.module, :perform_functions, ast)
  end


  defp generate_perform_body(ctx_var, :done) do
    quote do: Convex.Context.done(unquote(ctx_var))
  end

  defp generate_perform_body(ctx_var, {:done, ast}) do
    quote do: Convex.Context.done(unquote(ctx_var), unquote(ast))
  end

  defp generate_perform_body(ctx_var, {:failed, ast}) do
    quote do: Convex.Context.failed(unquote(ctx_var), unquote(ast))
  end

  defp generate_perform_body(ctx_var, ast) do
    quote do
      case unquote(ast) do
        :done -> Convex.Context.done(unquote(ctx_var))
        {:done, result} -> Convex.Context.done(unquote(ctx_var), result)
        {:failed, reason} -> Convex.Context.failed(unquote(ctx_var), reason)
      end
    end
  end


  defp generate_validate(caller, ctx_ast, _ctx_var, op, args, do_ast) do
    args_ast = parse_args(caller, args)
    {op_var, op_ast} = parse_operation(caller, op, :_)
    {args_var, body_ast} = generate_validate_body(do_ast)
    ast = quote do
      defp _validate(unquote(ctx_ast), unquote(op_ast) = unquote(op_var), unquote(args_ast) = unquote(args_var)) do
        unquote(body_ast)
      end
    end
    Module.put_attribute(caller.module, :validate_functions, ast)
  end


  defp generate_validate_body(:ok) do
    args_var = Macro.var(:args, __MODULE__)
    ast = quote do: {:ok, unquote(args_var)}
    {args_var, ast}
  end

  defp generate_validate_body({:ok, _} = ast) do
    args_var = Macro.var(:_, __MODULE__)
    {args_var, ast}
  end

  defp generate_validate_body({:error, _} = ast) do
    args_var = Macro.var(:_, __MODULE__)
    {args_var, ast}
  end

  defp generate_validate_body({:raise, _, [_|_]} = ast) do
    args_var = Macro.var(:_, __MODULE__)
    {args_var, ast}
  end

  defp generate_validate_body(ast) do
    args_var = Macro.var(:args, __MODULE__)
    ast = quote do
      case unquote(ast) do
        :ok -> {:ok, unquote(args_var)}
        {:ok, result} when is_map(result) -> {:ok, result}
        {:error, _reason} = error -> error
        result when is_map(result) -> {:ok, result}
      end
    end
    {args_var, ast}
  end


  defp operation_to_ast(caller, op) do
    case Regex.run(@operation_rx, op) do
      nil -> raise CompileError,
                    description: "invalide operation #{inspect op}",
                    file: caller.file, line: caller.line
      _ ->
        parts = Enum.map(String.split(op, "."), &String.to_atom/1)
        case Enum.split(parts, -2) do
          {[], [:*]} -> quote do: [_|_]
          {rest, [last, :*]} ->
            tail = [{:|, [], [last, {:_, [], nil}]}]
            rest ++ tail
          _ -> parts
        end
    end
  end

end