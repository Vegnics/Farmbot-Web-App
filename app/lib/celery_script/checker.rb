# Takes a corpus and an AST and tells you if it is syntactically valid.
# PROBABLY THE MOST COMPLICATED CODE IN ALL OF FARMBOT.
module CeleryScript
  class TypeCheckError < StandardError; end
  class Checker
    MISSING_ARG = "Expected node '%s' to have a '%s', but got: %s."
    EXTRA_ARGS  = "'%s' has unexpected arguments: %s. Allowed arguments: %s"
    BAD_LEAF    = "Expected leaf '%{kind}' within '%{parent_kind}'"\
                  " to be one of: %{allowed} but got %{actual}"
    MALFORMED   = "Expected '%s' to be a node or leaf, but it was neither"
    BAD_BODY    = "Body of '%s' node contains '%s' node. "\
                  "Expected one of: %s"
    UNBOUND_VAR = "Unbound variable: %s"
    T_MISMATCH  = "Type mismatch. %s must be one of: %s. Got: %s"

    # Certain CeleryScript pairing errors are more than just a syntax error.
    # For instance, A `nothing` node in a `variable_declaration` is often an
    # indication that the user did not fill out a value for a variable. In these
    # rare cases, we muct provide information beyond what is found in the
    # BAD_LEAF template.
    FRIENDLY_ERRORS = {
      nothing: {
        variable_declaration: "You must provide a value for all parameters"
      }
    }.with_indifferent_access
    attr_reader :tree, :corpus, :device

    # Device is required for security / permission checks.
    def initialize(tree, corpus, device)
      @tree, @corpus, @device = tree, corpus, device
      self.freeze
    end

    def run!
      CeleryScript::TreeClimber.travel(tree, method(:validate).to_proc)
      tree
    end

    def run
      error || tree
    end

    def valid?
      error ? false : true
    end

    def error
      run!
      nil
    rescue TypeCheckError => e
      e
    end

    def check_leaf(node)
      allowed  = corpus.values(node)
      actual   = node.value.class

      maybe_bad_leaf(node.kind, node.parent.kind, allowed, actual)
    end

    private

    def validate(node)
      p = node.try(:parent).try(:kind) || "root"
      validate_body(node)
      validate_node(node)
    end

    def validate_body(node)
      (node.body || []).each_with_index do |inner_node, i|
        allowed = corpus.bodies(node)
        body_ok = allowed.include?(inner_node.kind.to_sym)
        bad_body_kind(node, inner_node, i, allowed) unless body_ok
      end
    end

    def validate_node(node)
      check_arity(node)
      node.args.map { |array| check_arg_validity(*array) }
      corpus.validate_node(node)
    end

    def check_arity(node)
        allowed = corpus.args(node)
        allowed.map do |arg|
          has_key = node.args.has_key?(arg) || node.args.has_key?(arg.to_s)
          unless has_key
            msgs = node.args.keys.join(", ")
            msgs = "nothing" if msgs.length < 1
          msg = MISSING_ARG % [node.kind, arg, msgs]
          raise TypeCheckError, msg
          end
        end
      has      = node.args.keys.map(&:to_sym) # Either bigger or equal.
      required = corpus.args(node) # Always smallest.
      if !(has.length === required.length)
        extras = has - required
        raise TypeCheckError, (EXTRA_ARGS % [node.kind, extras, allowed])
      end
    end

    def check_arg_validity(key, value)
      case value
      when AstNode
        validate_node_pairing(key, value)
      when AstLeaf
        validate_leaf_pairing(key, value)
        check_leaf(value)
      else
        malformed_node!(key)
      end
      run_additional_validations(value, key)
    end

    # Don't delete this- it is currently unreachable code, but as soon as we
    # allow identifiers other than `point`, `tool` and `coordinate` we will
    # need it again (and can write tests)
    # def bad_var!(value, label, expected, actual)
    #   value.invalidate!(T_MISMATCH % [label, expected, actual])
    # end SEE_MY_NOTE =============================^ RC 4 Oct 18


    def type_check_parameter(var, expected)
      data_type = var.args[:data_type].value

      # Don't delete this- it is currently unreachable code, but as soon as we
      # allow identifiers other than `point`, `tool` and `coordinate` we will
      # need it again (and can write tests)
      # if !expected.include?(data_type)
      #   bad_var!(value, label, expected, actual)
      # end SEE_MY_NOTE =============================^ RC 4 Oct 18
    end


    def validate_node_pairing(key, value)
      actual  = value.kind
      allowed = corpus.fetchArg(key).allowed_values.map(&:to_s)
      # It would be safe to run type checking here.
      if (actual == "identifier")
        allowed_types  = allowed.without("identifier")
        # Resolve the identifier.
        # Someday, we might need to use the return value to perform more
        # in depth type checking. We're not there yet, though.
        # Currently we just need `resolve_variable!` to
        # catch unbound identifiers
        var = resolve_variable!(value)
        case var.kind
        when "parameter_declaration"
          type_check_parameter(var, allowed_types)
        when "variable_declaration"
          actual = var.args[:data_value].kind
        #   Don't delete this- it is currently unreachable code, but as soon as we
        #   allow identifiers other than `point`, `tool` and `coordinate` we will
        #   need it again (and can write tests)
        #   unless allowed_types.include?(actual)
        #     bad_var!(value, var.args[:label].value, allowed_types, actual)
        #   end
        # else
        #   raise ("Bad kind: " + var.kind)
        #  SEE_MY_NOTE =============================^ RC 4 Oct 18
        end
      end

      maybe_bad_leaf(value.kind, value.parent.kind, allowed, actual)
    end

    def maybe_bad_leaf(kind, parent_kind, allowed, actual)
      unless allowed.include?(actual)
        message = (FRIENDLY_ERRORS.dig(kind, parent_kind) || BAD_LEAF) % {
          kind:        kind,
          parent_kind: parent_kind,
          allowed:     allowed,
          actual:      actual
        }

        raise TypeCheckError, message
      end
    end

    def validate_leaf_pairing(key, value)
      actual  = value.value.class
      allowed = corpus.fetchArg(key).allowed_values
      maybe_bad_leaf(value.kind, value.parent.kind, allowed, actual)
    end

    def bad_body_kind(prnt, child, i, ok)
      raise TypeCheckError, (BAD_BODY % [prnt.kind, child.kind, ok.inspect])
    end

    def malformed_node!(expectation)
      raise TypeCheckError, (MALFORMED % expectation)
    end

    def run_additional_validations(node, expectation)
      corpus.arg_validator(expectation).call(node, device)
    end

    # Calling this method with only one paramter
    # indicates a starting condition 🏁
    def resolve_variable!(node, origin = node)
      locals = node.args[:locals]

      if locals&.kind === "scope_declaration"
        label  = origin.args[:label]&.value
        result = (locals.body || []).select do |x|
          x.args[:label]&.value == label
        end.first
        return result if result
      end

      case node.parent
      when AstNode
        # sequence: Check the `scope` arg
        # Keep recursing if we can't find a scope on this node.
        resolve_variable!(node.parent, origin)
      when nil # We've got an unbound variable.
        origin.invalidate!(UNBOUND_VAR % origin.args[:label].value)
      end
    end
  end
end
