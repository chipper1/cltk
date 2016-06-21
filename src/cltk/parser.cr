# coding: utf-8
# Description:	This file contains the base class for parsers that use CLTK.

############
# Requires #
############

# CLTK Language Toolkit
require "./cfg"
require "./ast"

# exceptions
require "./parser/exceptions/bad_token_exception"
require "./parser/exceptions/internal_parser_exception"
require "./parser/exceptions/parser_construction_exception"
require "./parser/exceptions/handled_error_exception"
require "./parser/exceptions/not_in_language_exception"
require "./parser/exceptions/useless_parser_exception"

require "./parser/environment"
require "./parser/parse_stack"
require "./parser/state"
require "./parser/prod_proc"
require "./parser/actions"
require "./parser/parser"

#######################
# Classes and Modules #
#######################

# The CLTK root module
module CLTK

  alias Type = ASTNode | Token | String | Symbol | Int32 | Float32 | Float64 | Bool | Nil | Array(Type) | Hash(String, Type)

  # The Parser class may be sub-classed to produce new parsers.  These
  # parsers have a lot of features, and are described in the main
  # documentation.
  class Parser
    # @return [Environment] Environment used by the instantiated parser.
    getter :env

    #################
    # Class Methods #
    #################

    # The overridden new prevents un-finalized parsers from being
    # instantiated.
    def self.new(*args)
      if @@symbols.nil?
	raise UselessParserException.new
      else
	super(*args)
      end
    end


    @@production_precs :  Array(String | {String, Int32} | Nil)
    @@production_precs_prepare = {} of Int32 => (String | Nil | {String, Int32})
    @@token_precs      : Hash(String, {String, Int32})          = {} of String => {String, Int32}
    @@grammar          : CLTK::CFG              = CLTK::CFG.new
    @@conflicts        : Hash(Int32, Array({ String, String })) = Hash( Int32, Array({ String, String }) ).new {|h, k| h[k] = Array({String, String}).new}
    @@prec_counts      : Hash(Symbol, Int32) = {:left => 0, :right => 0, :non => 0}
    @@token_hooks      = Hash(String, Array(Proc(Environment, Nil))).new do |h, k|
      h[k] = [] of Proc(Environment, Nil)
    end

    # Installs instance class variables into a class.
    #
    # @return [void]
    macro inherited
      @@symbols : Array(String)?
      @@start_symbol : String?
      @@env : (Environment.class) | Nil
      @@grammar_prime : CLTK::CFG?

      @@curr_lhs  = nil
      @@curr_prec = nil


      @@lh_sides  = {} of Int32 => String
      @@procs     = {} of Int32 => { ProdProc, Int32 }
      @@states    = Array(State).new

      # Variables for dealing with precedence.

      # Set the default argument handling policy.  Valid values
      # are :array and :splat.
      @@default_arg_type = :splat

      @@grammar.callback do |type, which, p, sels|
        proc = case type
	       when :optional
	         case which
	         when :empty then ProdProc.new { nil }
	         else             ProdProc.new { |o| o[0] }
	         end

	       when :elp
	         case which
	         when :empty then ProdProc.new { [] of CLTK::Type}
	         else             ProdProc.new { |prime| prime[0] }
	         end
	       when :nelp
	         case which
	         when :single
	           ProdProc.new { |el| [el[0]].map { |x| x as CLTK::Type } }
	         when :multiple
	           ProdProc.new(:splat, sels) do |syms|
                     syms  = syms as Array
                     first = syms.shift as Array
                     rest  = syms.size > 1 ? syms : syms.first
                     first << rest
	           end
	         else
	           ProdProc.new do |el|
                     el = el as Array
                     el.size > 1 ? el : el.first
                   end
	         end
               else
                 raise "this should never happen"
	       end
	@@procs.not_nil![p.id] = { proc, p.rhs.size }
	@@production_precs_prepare[p.id] = p.last_terminal
        nil
      end
    end

    def self.parser
      Parser.new(@@symbols, @@lh_sides, @@states, @@procs, @@token_hooks, @@env)
    end
    # If *state* (or its equivalent) is not in the state list it is
    # added and it's ID is returned.  If there is already a state
    # with the same items as *state* in the state list its ID is
    # returned and *state* is discarded.
    #
    # @param [State] state State to add to the parser.
    #
    # @return [Integer] The ID of the state.
    def self.add_state(state)
      states = @@states.not_nil!
      id = states.index(state)
      if id
	id
      else
	state.id = states.size
	states << state
	states.size - 1
      end
    end

    # Build a hash with the default options for Parser.finalize
    # and then update it with the values from *opts*.
    #
    # @param [Hash{Symbol => Object}] opts Hash containing options for finalize.
    #
    # @return [Hash{Symbol => Object}]
    private def self.build_finalize_opts(opts : Hash)

      opts[:explain] =
        opts[:explain] ?
          self.get_io(opts[:explain] as String) : nil

      {
	explain =>    false,
	lookahead =>  true,
	precedence => true,
	use =>        false
      }.merge(opts)
    end

    def self.setenv(env)
      @@env = env
    end

    # This method is used to (surprise) check the sanity of the
    # constructed parser.  It checks to make sure all non-terminals
    # used in the grammar definition appear on the left-hand side of
    # one or more productions, and that none of the parser's states
    # have invalid actions.  If a problem is encountered a
    # ParserConstructionException is raised.
    #
    # @return [void]
    def self.check_sanity
      # Check to make sure all non-terminals appear on the
      # left-hand side of some production.
      @@grammar.nonterms.each do |sym|
	unless @@lh_sides.not_nil!.values.includes?(sym)
	  raise Exception.new "Non-terminal #{sym} does not appear on the left-hand side of any production."
	end
      end
      # Check the actions in each state.
      each_state do |state|
	state.actions.not_nil!.each do |sym, actions|
	  if CFG.is_terminal?(sym)
	    # Here we check actions for terminals.
	    actions.each do |action|
	      if action.is_a?(Accept)
		if sym.to_s != "EOS"
		  raise ParserConstructionException.new "Accept action found for terminal #{sym} in state #{state.id}."
		end

	      elsif !(action.is_a?(GoTo) || action.is_a?(Reduce) || action.is_a?(Shift))
		raise ParserConstructionException.new "Object of type #{action.class} found in actions for terminal " +
						   "#{sym} in state #{state.id}."

	      end
	    end

	    if (conflict = state.conflict_on?(sym))
	      self.inform_conflict(state.id, conflict, sym)
	    end
	  else
	    # Here we check actions for non-terminals.
	    if actions.size > 1
	      raise ParserConstructionException.new "State #{state.id} has multiple GoTo actions for non-terminal #{sym}."

	    elsif actions.size == 1 && !actions.first.is_a?(GoTo)
	      raise ParserConstructionException.new "State #{state.id} has non-GoTo action for non-terminal #{sym}."

	    end
	  end
	end
      end
    end

    # This method checks to see if the parser would be in parse state
    # *dest* after starting in state *start* and reading *symbols*.
    #
    # @param [Symbol]         start    Symbol representing a CFG production.
    # @param [Symbol]         dest     Symbol representing a CFG production.
    # @param [Array<Symbol>]  symbols  Grammar symbols.
    #
    # @return [Boolean] If the destination symbol is reachable from the start symbol after reading *symbols*.
    def self.check_reachability(start, dest, symbols)
      path_exists = true
      cur_state   = start

      symbols.each do |sym|

	actions = @@states.not_nil![cur_state.id.not_nil!].on?(sym)
	actions = actions.select { |a| a.is_a?(Shift) } if CFG.is_terminal?(sym)

	if actions.empty?
	  path_exists = false
	  break
	end

	# There can only be one Shift action for terminals and
	# one GoTo action for non-terminals, so we know the
	# first action is the only one in the list.
	cur_state = @@states.not_nil![actions.first.id.not_nil!]
      end

      path_exists && cur_state.id == dest.id
    end

    # Declares a new clause inside of a production.  The right-hand
    # side is specified by *expression* and the precedence of this
    # production can be changed by setting the *precedence* argument
    # to some terminal symbol.
    #
    # @param [String, Symbol]  expression  Right-hand side of a production.
    # @param [Symbol]          precedence  Symbol representing the precedence of this production.
    # @param [:array, :splat]  arg_type    Method to use when passing arguments to the action.
    # @param [Proc]            action      Action to be taken when the production is reduced.
    #
    # @return [void]
    macro clause(expression, precedence = nil, arg_type = nil, &action: _ -> _)
      # Use the curr_prec only if it isn't overridden for this
      # clause.
      Tuple.new({{expression}}, {{precedence}}, {{arg_type}}).tap do |param_tupel|

        expression = param_tupel[0]
        precedence = param_tupel[1] || @@curr_prec
        arg_type   = param_tupel[2]

        production, selections = if @@grammar
                                   (@@grammar as CLTK::CFG).clause({{expression}}).values
                                 else
                                   raise "NO GRAMMAR DEFINED"
                                 end
        expected_arity = (selections.empty? ? production.rhs.size : selections.size)
        if arg_type == :splat && {{action.args.size}} != expected_arity
  	  raise CLTK::ParserConstructionException.new "Incorrect number of action parameters.  Expected #{expected_arity} but got {{action.args.size}}. Action arity must match the number of terminals and non-terminals in the clause."
        end

        # Add the action to our proc list.
        @@procs.not_nil![production.id] = {
          ## new ProdProc
          ProdProc.new(:splat, selections) do |%a, %env|
            %env.yield_with_self do
              {%for arg, index in action.args%}
                {{arg}} = (%a as Array(CLTK::Type))[{{index}}]
              {%end%}
              # reassign the first block argument to
              # the whole arguments array if arg_type
              # evaluates to :array
              {%if action.args.size > 0%}
                if (arg_type || @@default_arg_type) == :array
                  {{action.args.first}} = %a as Array
                end
              {%end %}
              result = begin
                          {{action.body}}
                        end
              if result.is_a? Array
                result.map { |r| r as CLTK::Type}
              else
                result as CLTK::Type
              end
            end
          end,
          production.rhs.size
        }
        # If no precedence is specified use the precedence of the
        # last terminal in the production.
        @@production_precs_prepare[production.id] = precedence || production.last_terminal
      end
    end

    def self.c(expression, precedence = nil, arg_type = @@default_arg_type, &action: Array(Type), Environment -> _)
      self.clause(expression, precedence, arg_type, &action)
    end
    # Removes resources that were needed to generate the parser but
    # aren't needed when actually parsing input.
    #
    # @return [void]
    def self.clean
      # We've told the developer about conflicts by now.
      @@conflicts = nil

      # Drop the grammar and the grammar'.
      #@@grammar       = nil
      @@grammar_prime = nil

      # Drop precedence and bookkeeping information.
      @@curr_lhs  = nil
      @@curr_prec = nil

      @@prec_counts      = nil
      #@@production_precs = nil
      @@token_precs      = nil

      # Drop the items from each of the states.
      each_state { |state| state.clean }
    end

    # Set the default argument type for the actions associated with
    # clauses.  All actions defined after this call will be passed
    # arguments in the way specified here, unless overridden in the
    # call to {Parser.clause}.
    #
    # @param [:array, :splat] type The default argument type.
    #
    # @return [void]
    def self.default_arg_type(type)
      @@default_arg_type = type if type == :array || type == :splat
    end

    def self.dat(type)
      self.default_arg_type(type)
    end
    # Adds productions and actions for parsing empty lists.
    #
    # @see CFG#empty_list_production
    def self.build_list_production(symbol, list_elements, separator = "")
      if list_elements.is_a? Array
        list_elements = list_elements.map {|e| e.to_s}
      else
        list_elements = list_elements.to_s
      end
      @@grammar.build_list_production(symbol.to_s, list_elements, separator.to_s)
    end

    def self.list(symbol, list_elements, separator = "")
      self.build_list_production(symbol, list_elements, separator)
    end

    # This function will print a description of the parser to the
    # provided IO object.
    #
    # @param [IO] io Input/Output object used for printing the parser's explanation.
    #
    # @return [void]
    def self.explain(io : IO)
      if @@grammar && !@@states.not_nil!.empty?
	io.puts("###############")
	io.puts("# Productions #")
	io.puts("###############")
	io.puts

	max_id_length = @@grammar.productions_id.not_nil!.size.to_s.size

	# Print the productions.
	@@grammar.productions.not_nil!.each do |sym, productions|
          productions = productions as Array(CLTK::CFG::Production)
	  max_rhs_length = (productions).reduce(0) do |m, p|
            if (len = p.to_s.not_nil!.size) > m
              len
            else
              m
            end
          end

	  productions.not_nil!.each do |production|
	    p_string = production.to_s

            #	      io.print("\tProduction #{sprintf("%#{max_id_length}d", production.id)}: #{p_string}")
            prec = @@production_precs_prepare[production.id];
	    if (prec.is_a?({Int32, String}))
	      io.print(" " * (max_rhs_length - p_string.not_nil!.size))
	      io.print(" : (#{sprintf("%-5s", prec.first)}, #{prec.last})")
	    end

	    io.puts
	  end

	  io.puts
	end

	io.puts("##########")
	io.puts("# Tokens #")
	io.puts("##########")
	io.puts

	max_token_len = @@grammar.terms.reduce(0) do |m, t|
          if t.size > m
            t.size
          else m
          end
        end

	@@grammar.terms.to_a.sort {|a,b| a.to_s <=> b.to_s }.each do |term|
	  io.print("\t#{term}")

	  if (prec = @@token_precs.not_nil![term])
	    io.print(" " * (max_token_len - term.size))
	    io.print(" : (#{sprintf("%-5s", prec.first)}, #{prec.last})")
	  end

	  io.puts
	end

	io.puts

	io.puts("#####################")
	io.puts("# Table Information #")
	io.puts("#####################")
	io.puts

	io.puts("\tStart symbol: #{@@grammar.start_symbol}'")
	io.puts

	io.puts("\tTotal number of states: #{@@states.not_nil!.size}")
	io.puts

	io.puts("\tTotal conflicts (maybe wrong - flatten impl): #{@@conflicts.not_nil!.values.flatten.size}")
	io.puts

	@@conflicts.not_nil!.each do |state_id, conflicts|
	  io.puts("\tState #{state_id} has #{@@conflicts.not_nil!.size} conflict(s)")
	end
        @@conflicts = @@conflicts.not_nil!
	io.puts unless @@conflicts.not_nil!.empty?

	# Print the parse table.
	io.puts("###############")
	io.puts("# Parse Table #")
	io.puts("###############")
	io.puts

	each_state do |state|
	  io.puts("State #{state.id}:")
	  io.puts

	  io.puts("\t# ITEMS #")
	  max = state.items.not_nil!.reduce(0) do |max, item|
	    if item.lhs.to_s.size > max
              item.lhs.to_s.size
            else
              max
            end
	  end

	  state.each do |item|
	    io.puts("\t#{item.to_s(max)}")
	  end

	  io.puts
	  io.puts("\t# ACTIONS #")

	  state.actions.not_nil!.keys.sort {|a,b| a.to_s <=> b.to_s}.each do |sym|
	    state.actions.not_nil![sym].each do |action|
	      io.puts("\tOn #{sym} #{action}")
	    end
	  end

	  io.puts
	  io.puts("\t# CONFLICTS #")

	  if @@conflicts.not_nil![state.id.not_nil!].size == 0
	    io.puts("\tNone\n\n")
	  else
	    @@conflicts.not_nil![state.id.not_nil!].each do |conflict|
	      type, sym = conflict

	      io.print("\t#{if type == :SR; "Shift/Reduce"; else "Reduce/Reduce"; end} conflict")

	      io.puts(" on #{sym}")
	    end

	    io.puts
	  end
	end

	# Close any IO objects that aren't $stdout.
	if io.is_a?(IO)
          if io != $stdout
            #io.close
          end
        end
      else
	#raise ParserConstructionException.new "Parser.explain called outside of finalize."
      end
    end
    # This method will finalize the parser causing the construction
    # of states and their actions, and the resolution of conflicts
    # using lookahead and precedence information.
    #
    # No calls to {Parser.production} may appear after the call to
    # Parser.finalize.
    #
    # @param [Hash] opts Options describing how to finalize the parser.
    #
    # @option opts [Boolean,String,IO]  :explain     To explain the parser or not.
    # @option opts [Boolean]            :lookahead   To use lookahead info for conflict resolution.
    # @option opts [Boolean]            :precedence  To use precedence info for conflict resolution.
    # @option opts [String,IO]          :use         A file name or object that is used to load/save the parser.
    #
    # @return [void]
    def self.finalize(opts : Hash(Symbol, Bool | String | IO) = {lookahead: true, precedence: true} )
      if (@@grammar.productions_sym as Hash(String, Array(CLTK::CFG::Production))).empty?
	#raise ParserConstructionException,
	raise Exception.new "Parser has no productions.  Cowardly refusing to construct an empty parser."
      end

      # Get the full options hash.
#      if (opts.is_a? Hash(Symbol, Bool | String ))
#        opts = {
#          lookahead: true,
#	  precedence: true
#        }.merge opts
#      end
      # Get the name of the file in which the parser is defined.
      #
      # FIXME: See why this is failing for the simple ListParser example.
      def_file = caller()[2].split(':')[0] if opts.has_key? :use

      # Check to make sure we can load the necessary information
      # from the specified object.
      if opts.has_key? :use
        raise Exception.new "reading the parser from a file is not yet supported"
#        && (
#	   (opts[:use].is_a?(String) && File.exists?(opts[:use] as String) #&& File::Stat.mtime(opts[:use]) > File.mtime(def_file)
#           ) ||
#	   (opts[:use].is_a?(File) #&& opts[:use].mtime > File.mtime(def_file)
#           )
#	 )
#
#	file = self.get_io(opts[:use], 'r')
#
#	# Un-marshal our saved data structures.
##	file.flock(File::LOCK_SH)
#	@lh_sides, @states, @symbols = Marshal.load(file)
##	file.flock(File::LOCK_UN)
#
#	# Close the file if we opened it.
#	file.close if opts[:use].is_a?(String)
#
#	# Remove any un-needed data and return.
#	return self.clean
      end

      # Grab all of the symbols that comprise the grammar
      # (besides the start symbol).
      @@symbols = @@grammar.symbols.to_a + ["ERROR"]
      # Add our starting state to the state list.
      @@start_symbol      = (@@grammar.start_symbol.to_s + "\'")
      start_production    = @@grammar.production(@@start_symbol as String, @@grammar.start_symbol as String)[:production]
      start_state         = State.new(@@symbols, [start_production.to_item])
      start_state.close(@@grammar.productions_sym)
      self.add_state(start_state)

      # Translate the precedence of productions from tokens to
      # (associativity, precedence) pairs.
      @@production_precs = @@production_precs_prepare.map do |id, prec|
        @@token_precs.not_nil![prec]?
      end
      # Build the rest of the transition table.
      each_state do |state|
        # Transition states.
        tstates = Hash(String, State).new {|h,k| h[k] = State.new(@@symbols) }

	#Bin each item in this set into reachable transition
	#states.

	state.each do |item|
	  if (next_symbol = item.next_symbol)
            unless tstates[next_symbol]?
              tstates[next_symbol] = State.new(@@symbols)
            end
            tstates[next_symbol] << item.copy
	  end
	end
	# For each transition state:
	#  1) Get transition symbol
	#  2) Advance dot
	#  3) Close it
	#  4) Get state id and add transition
	tstates.each do |symbol, tstate|
	  tstate.each { |item| item.advance }

	  tstate.close(@@grammar.productions_sym as Hash(String, Array(CLTK::CFG::Production)))

	  id = self.add_state(tstate)

	  # Add Goto and Shift actions.
	  state.on(symbol, CFG.is_nonterminal?(symbol) ? GoTo.new(id) : Shift.new(id))
	end

	# Find the Accept and Reduce actions for this state.
	state.each do |item|
	  if item.at_end?
	    if item.lhs == @@start_symbol
	      state.on("EOS", Accept.new)
	    else
	      state.add_reduction(
                (@@grammar.productions_id as Hash(Int32, CLTK::CFG::Production))[item.id]
              )
	    end
	  end
	end
      end

      # Build the production.id -> production.lhs map.
      @@grammar.productions_id.each do |id, production|
        @@lh_sides[id as Int32] = (production as CLTK::CFG::Production).not_nil!.lhs
      end

      # Prune the parsing table for unnecessary reduce actions.
      self.prune(opts[:lookahead]?, opts[:precedence]?)

      # Check the parser for inconsistencies.
      self.check_sanity

      # Print the table if requested.
      exp = opts[:explain]?
      if exp.is_a? IO
        self.explain(exp)
      end

      # Remove any data that is no longer needed.
      self.clean
      # Store the parser's final data structures if requested.
      if opts[:use]?
        raise Exception.new "storing the parser to a file is not yet supported"
        #	io = self.get_io(opts[:use])
        #
        #	io.flock(File::LOCK_EX) if io.is_a?(File)
        #	Marshal.dump([@lh_sides, @states, @symbols], io)
        #	io.flock(File::LOCK_UN) if io.is_a?(File)
        #
        #	# Close the IO object if we opened it.
        #	io.close if opts[:use].is_a?(String)
      end
    end

    # Converts an object into an IO object as appropriate.
    #
    # @param [Object]  o     Object to be converted into an IO object.
    # @param [String]  mode  String representing the mode to open the IO object in.
    #
    # @return [IO, false] The IO object or false if a conversion wasn't possible.
    def self.get_io(o, mode = "w")
      if o.is_a?(Bool)
        STDOUT
      elsif o.is_a?(String)
	File.open(o, mode).read
      elsif o.is_a?(IO)
	o
      else
	false
      end
    end

    # Iterate over the parser's states.
    #
    # @yieldparam [State]  state  One of the parser automaton's state objects
    #
    # @return [void]
    def self.each_state
      current_state = 0
      while current_state < @@states.not_nil!.size
	yield @@states.not_nil!.at(current_state)
	current_state += 1
      end
    end

    # @return [CFG]  The grammar that can be parsed by this Parser.
    def self.grammar
      @@grammar.clone
    end

    # This method generates and memoizes the G' grammar used to
    # calculate the LALR(1) lookahead sets.  Information about this
    # grammar and its use can be found in the following paper:
    #
    # Simple Computation of LALR(1) Lookahead Sets
    # Manuel E. Bermudez and George Logothetis
    # Information Processing Letters 31 - 1989
    #
    # @return [CFG]
    def self.grammar_prime
      unless @@grammar_prime
	@@grammar_prime = CFG.new

	each_state do |state|
	  state.each do |item|
	    lhs = "#{state.id}_#{item.next_symbol}".to_s

	    next unless CFG.is_nonterminal?(item.next_symbol) &&
                        !(@@grammar_prime.not_nil!.productions_sym as Hash(String, Array(CLTK::CFG::Production)))
                          .keys.includes?(lhs)

	    (@@grammar.productions_sym as Hash(String, Array(CLTK::CFG::Production)))
              .not_nil![item.next_symbol.not_nil!].each do |production|
	      rhs = ""

	      cstate = state

	      production.rhs.each do |symbol|
		rhs += "#{cstate.id}_#{symbol} "

		cstate = @@states.not_nil![cstate.on?(symbol).first.id.not_nil!]
	      end

	      @@grammar_prime.not_nil!.production(lhs, rhs)
	    end
	  end
	end
      end

      @@grammar_prime
    end

    # Inform the parser core that a conflict has been detected.
    #
    # @param [Integer]   state_id  ID of the state where the conflict was encountered.
    # @param [:RR, :SR]  type      Reduce/Reduce or Shift/Reduce conflict.
    # @param [Symbol]    sym       Symbol that caused the conflict.
    #
    # @return [void]
    def self.inform_conflict(state_id, type, sym)
      @@conflicts.not_nil![state_id.not_nil!] << {type.to_s, sym}
    end

    # This method is used to specify that the symbols in *symbols*
    # are left-associative.  Subsequent calls to this method will
    # give their arguments higher precedence.
    #
    # @param [Array<Symbol>]  symbols  Symbols that are left associative.
    #
    # @return [void]
    def self.left(*symbols)
      prec_level = @@prec_counts.not_nil![:left] += 1

      symbols.map do |sym|
	@@token_precs.not_nil![sym.to_s] = {:left.to_s, prec_level}
      end
    end

    # This method is used to specify that the symbols in *symbols*
    # are non-associative.
    #
    # @param [Array<Symbol>]  symbols  Symbols that are non-associative.
    #
    # @return [void]
    def self.nonassoc(*symbols)
      prec_level = @prec_counts[:non] += 1

      symbols.map { |s| s.to_sym }.each do |sym|
	@token_precs[sym] = [:non, prec_level]
      end
    end

    # Adds productions and actions for parsing nonempty lists.
    #
    # @see CFG#nonempty_list_production
    def self.build_nonempty_list_production(symbol : String | Symbol, list_elements, separator = "")
      if list_elements.is_a? Array
        list_elements = list_elements.map do |e|
          if e
            e.to_s
          else
            ""
          end
        end
      else
        list_elements = list_elements.to_s
      end
      @@grammar.build_nonempty_list_production(symbol.to_s, list_elements, separator.to_s)
    end

    def self.nonempty_list(symbol, list_elements, separator = "")
      self.build_nonempty_list_production(symbol, list_elements, separator)
    end
    # This function is where actual parsing takes place.  The
    # _tokens_ argument must be an array of Token objects, the last
    # of which has type EOS.  By default this method will return the
    # value computed by the first successful parse tree found.
    #
    # Additional information about the parsing options can be found in
    # the main documentation.
    #
    # @param [Array<Token>]  tokens  Tokens to be parsed.
    # @param [Hash]          opts    Options to use when parsing input.
    #
    # @option opts [:first, :all]       :accept      Either :first or :all.
    # @option opts [Object]             :env         The environment in which to evaluate the production action.
    # @option opts [Boolean,String,IO]  :parse_tree  To print parse trees in the DOT language or not.
    # @option opts [Boolean,String,IO]  :verbose     To be verbose or not.
    #
    # @return [Object, Array<Object>]  Result or results of parsing the given tokens.
    def self.parse(tokens, opts = {} of Symbol => (Symbol))
      parser.parse(tokens, opts)
    end

    # Adds a new production to the parser with a left-hand value of
    # *symbol*.  If *expression* is specified it is taken as the
    # right-hand side of the production and *action* is associated
    # with the production.  If *expression* is nil then *action* is
    # evaluated and expected to make one or more calls to
    # Parser.clause.  A precedence can be associate with this
    # production by setting *precedence* to a terminal symbol.
    #
    # @param [Symbol]				symbol		Left-hand side of the production.
    # @param [String, Symbol, nil]	expression	Right-hand side of the production.
    # @param [Symbol, nil]			precedence	Symbol representing the precedence of this produciton.
    # @param [:array, :splat]		arg_type		Method to use when passing arguments to the action.
    # @param [Proc]				action		Action associated with this production.
    #
    # @return [void]
    macro production(symbol, expression = nil, precedence = nil, arg_type = nil, &action: _ -> _)
      # Check the symbol.
      symbol = {{symbol}}
      expression = {{expression}}
      precedence = {{precedence}}
      arg_type = {{arg_type}}

      if !(symbol.is_a?(Symbol) || symbol.is_a?(String)) || !CLTK::CFG.is_nonterminal?(symbol)
        raise Exception.new "Production symbols must be Strings or Symbols and be in all lowercase."
      end

      @@grammar.curr_lhs = symbol.to_s
      @@curr_prec        = precedence
      @@orig : Symbol? = @@default_arg_type
      if {{arg_type}}
        @@default_arg_type = {{arg_type}}
      end
      {%if expression%}
        clause({{expression}}, {{precedence}}, {{arg_type}}) do |{{*action.args}}|
          {{action.body}}
        end
      {%else%}
          {{action.body}}
      {%end%}

      @@default_arg_type = @@orig

      @@grammar.curr_lhs = nil
      @@curr_prec        = nil

    end


    def self.p(symbol, expression = nil, precedence = nil, arg_type = @@default_arg_type, &action: Array(Type), Environment -> _)
      self.production(symbol, expression, precedence, arg_type, &action)
    end

    def self.p(symbol, expression = nil, precedence = nil, arg_type = @@default_arg_type, &action: Array(Type), Environment -> _)
      self.production(symbol, expression, precedence, arg_type, &action)
    end
    # This method uses lookahead sets and precedence information to
    # resolve conflicts and remove unnecessary reduce actions.
    #
    # @param [Boolean]  do_lookahead   Prune based on lookahead sets or not.
    # @param [Boolean]  do_precedence  Prune based on precedence or not.
    #
    # @return [void]
    def self.prune(do_lookahead, do_precedence)
      terms = @@grammar.terms

      # If both options are false there is no pruning to do.
      return if !(do_lookahead || do_precedence)

      each_state do |state0|

	#####################
	# Lookahead Pruning #
	#####################

	if do_lookahead
	  # Find all of the reductions in this state.
	  reductions = state0.actions.not_nil!.values.flatten.uniq.select { |a| a.is_a?(Reduce) }
          # reduction is ok ..
	  reductions.each do |reduction|
            raction_id = (reduction as Action).id.not_nil!
	    production = (@@grammar.productions_id as Hash(Int32, CLTK::CFG::Production))[raction_id]
	    lookahead = Array(String).new

	    # Build the lookahead set.
	    each_state do |state1|
	      if self.check_reachability(state1, state0, production.rhs)
		lookahead |= self.grammar_prime.not_nil!.follow_set("#{state1.id}_#{production.lhs}".to_s)
	      end
	    end

	    # Translate the G' follow symbols into G
	    # lookahead symbols.
	    lookahead = lookahead.map { |sym| sym.to_s.split('_', 2).last }.uniq

	    # Here we remove the unnecessary reductions.
	    # If there are error productions we need to
	    # scale back the amount of pruning done.
	    pruning_candidates = terms.to_a - lookahead

	    if terms.includes?("ERROR")
	      pruning_candidates.each do |sym|
		state0.actions.not_nil![sym].delete(reduction) if state0.conflict_on?(sym)
	      end
	    else
	      pruning_candidates.each { |sym| state0.actions.not_nil![sym].delete(reduction) }
	    end
	  end
	end

	########################################
	# Precedence and Associativity Pruning #
	########################################

	if do_precedence
	  state0.actions.not_nil!.each do |symbol, actions|

	    # We are only interested in pruning actions
	    # for terminal symbols.
	    next unless CFG.is_terminal?(symbol)

	    # Skip to the next one if there is no
	    # possibility of a Shift/Reduce or
	    # Reduce/Reduce conflict.
	    next unless actions && actions.size > 1
	    resolve_ok = actions.reduce(true) do |m, a|
	      if a.is_a?(Reduce)
		m && @@production_precs[a.id.not_nil!]
	      else
		m
	      end
	    end && actions.reduce(false) { |m, a| m  || a.is_a?(Shift) }

	    if @@token_precs.not_nil!.has_key?(symbol) && @@token_precs.not_nil![symbol] && resolve_ok
	      max_prec = 0
	      selected_action = nil
	      # Grab the associativity and precedence
	      # for the input token.
	      tassoc, tprec = @@token_precs.not_nil![symbol]

	      actions.each do |a|
		assoc, prec = (
                  a.is_a?(Shift) ? {tassoc, tprec} : @@production_precs[a.id.not_nil!]
                ) as {String, Int32}

		# If two actions have the same precedence we
		# will only replace the previous production if:
		#  * The token is left associative and the current action is a Reduce
		#  * The token is right associative and the current action is a Shift
		if prec > max_prec  || (prec == max_prec && tassoc == (a.is_a?(Shift) ? :right : :left))
		  max_prec        = prec
		  selected_action = a

		elsif prec == max_prec && assoc == :nonassoc
		  raise Exception.new "Non-associative token found during conflict resolution."

		end
	      end

	      state0.actions.not_nil![symbol] = [selected_action.not_nil! as Action]
	    end
	  end
	end
      end
    end

    # This method is used to specify that the symbols in _symbols_
    # are right associative.  Subsequent calls to this method will
    # give their arguments higher precedence.
    #
    # @param [Array<Symbol>] symbols Symbols that are right-associative.
    #
    # @return [void]
    def self.right(*symbols)
      prec_level = @@prec_counts.not_nil![:right] += 1

      symbols.map do |sym|
	@@token_precs.not_nil![sym.to_s] = {:right.to_s, prec_level}
      end
    end

    # Changes the starting symbol of the parser.
    #
    # @param [Symbol] symbol The starting symbol of the grammar.
    #
    # @return [void]
    def self.start(symbol)
      @grammar.start symbol
    end

    # Add a hook that is executed whenever *sym* is seen.
    #
    # The *sym* must be a terminal symbol.
    #
    # @param [Symbol]  sym   Symbol to hook into
    # @param [Proc]    proc  Code to execute when the block is seen
    #
    # @return [void]
    def self.token_hook(sym, &proc: Proc(Environment, Nil))
      if CFG.is_terminal?(sym)
	@@token_hooks.not_nil![sym.to_s] << proc
      else
	raise "Method token_hook expects `sym` to be non-terminal."
      end
    end


    ####################
    # Instance Methods #
    ####################

    # Instantiates a new parser and creates an environment to be
    # used for subsequent calls.
    @env : Environment
    def  initialize
      @env = (@@env || Environment).new
    end

    # Parses the given token stream using the encapsulated environment.
    #
    # @see .parse
    def parse(tokens)
      self.class.parse(tokens, {:env => @env})
    end
  end
end
