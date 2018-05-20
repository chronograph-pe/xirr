module Xirr

	# Expands [Array] to store a set of transactions which will be used to calculate the XIRR
	# @note A Cashflow should consist of at least two transactions, one positive and one negative.
	class Cashflow < Array
		require 'timeout'
		attr_reader :raise_exception, :fallback, :iteration_limit, :options

		# @param args [Transaction]
		# @example Creating a Cashflow
		#   cf = Cashflow.new
		#   cf << Transaction.new( 1000, date: '2013-01-01'.to_date)
		#   cf << Transaction.new(-1234, date: '2013-03-31'.to_date)
		#   Or
		#   cf = Cashflow.new Transaction.new( 1000, date: '2013-01-01'.to_date), Transaction.new(-1234, date: '2013-03-31'.to_date)
		def initialize(flow: [], period: Xirr::PERIOD, ** options)
			@period   = period
			@fallback = options[:fallback] || Xirr::FALLBACK
			@options  = options
			self << flow
			self.flatten!
		end

		# Check if Cashflow is invalid
		# @return [Boolean]
		def invalid?
			inflow.empty? || outflows.empty?
		end

		# Inverse of #invalid?
		# @return [Boolean]
		def valid?
			!invalid?
		end

		# @return [Float]
		# Sums all amounts in a cashflow
		def sum
			self.map(&:amount).sum
		end

		# Last investment date
		# @return [Time]
		def max_date
			@max_date ||= self.map(&:date).max
		end

		def during(start_date, end_date)
			Cashflow.new.concat(self.select{ |x| x.date > start_date && x.date <= end_date })
		end

		def before(end_date)
			Cashflow.new.concat(self.select{ |x| x.date <= end_date })
		end

		def after(start_date)
			Cashflow.new.concat(self.select{ |x| x.date > start_date })
		end

		def on(date)
			Cashflow.new.concat(self.select{ |x| x.date == date })
		end

		def start_nav_on(date)
			Transaction.new(self.select{ |x| x.date == date && x.type == "Net Asset Value"}.map{ |x| -x.amount.abs }.sum, date, "Investment Call")
		end

		def end_nav_on(date)
			Transaction.new(self.select{ |x| x.date == date && x.type == "Net Asset Value"}.map{ |x| x.amount.abs }.sum, date, "Net Asset Value")
		end

		def sort
			self.sort! { |x, y| x.date <=> y.date }
		end

		def sum_called
			-self.select{ |x| x.type == 'Investment Call' }.map(&:amount).sum
		end

		def sum_distributed
			self.select{ |x| x.type == 'Distribution' }.map(&:amount).sum
		end

		def sum_nav
			self.select{ |x| x.type == 'Net Asset Value' }.map(&:amount).sum
		end

		def moic
			numer = self.sum_distributed + self.sum_nav
			denom = self.sum_called
			denom != 0 ? numer / denom : nil
		end

		def sum_inflows
			self.map(&:amount).select{|x| x > 0}.sum
		end

		def sum_outflows
			-self.map(&:amount).select{|x| x < 0}.sum
		end

		# def moic
		# 	moic = (denom = self.sum_outflows) != 0 ? self.sum_inflows / denom : nil
		# end

		def bounded_moic(upper_bound = 10.0)
			m = moic
			(!m.blank? && m >= upper_bound ? nil : m)
		end

		# Calculates a simple IRR guess based on period of investment and multiples.
		# @return [Float]
		def irr_guess
			return @irr_guess = 0.0 if periods_of_investment.zero?
			@irr_guess = valid? ? ((multiple ** (1 / periods_of_investment)) - 1).round(3) : 0
			@irr_guess == 1.0/0 ? 0.0 : @irr_guess
		end

		# @param guess [Float]
		# @param method [Symbol]
		# @return [Float]
		def xirr(guess: 0.08, method: nil, ** options)
			method, options = process_options(method, options)
			if invalid?
				raise ArgumentError, invalid_message if options[:raise_exception]
				BigDecimal.new(0, Xirr::PRECISION)
			else
				begin
					Timeout::timeout(2.500) do
					  xirr = choose_(method).send :xirr, guess, options
						xirr = choose_(other_calculation_method(method)).send(:xirr, guess, options) if (xirr.nil? || xirr.nan?) && fallback
						xirr || Xirr::REPLACE_FOR_NIL
					end
				rescue Timeout::Error
					puts 'Timeout.'
					nil
				end
			end
		end

		def bounded_xirr(upper_bound = 1.0)
			x = xirr
			(!x.blank? && (x >= upper_bound || x == -1.0)) ? nil : x
		end

		def process_options(method, options)
			@temporary_period         = options[:period]
			options[:raise_exception] ||= @options[:raise_exception] || Xirr::RAISE_EXCEPTION
			options[:iteration_limit] ||= @options[:iteration_limit] || Xirr::ITERATION_LIMIT
			return switch_fallback(method), options
		end

		# If method is defined it will turn off fallback
		# it return either the provided method or the system default
		# @param method [Symbol]
		# @return [Symbol]
		def switch_fallback method
			if method
				@fallback = false
				method
			else
				@fallback = Xirr::FALLBACK
				Xirr::DEFAULT_METHOD
			end
		end

		def other_calculation_method(method)
			method == :newton_method ? :bisection : :newton_method
		end

		def aggregate_cf
			aggregated = []
			self.group_by{|cf| [cf.date, cf.type]}.each do |(date, type), cfs|
				sum = cfs.map(&:amount).compact.sum
				aggregated = aggregated.push(Transaction.new(sum, date, type)) if sum != 0
			end
			Cashflow.new.concat(aggregated)
		end

		def compact_cf
			compact = Hash.new 0
			self.each { |flow| compact[flow.date] += flow.amount if flow.amount != 0 }
			Cashflow.new flow: compact.map { |key, value| Transaction.new(value, key, "Compact") }, options: options, period: period
		end

		# First investment date
		# @return [Time]
		def min_date
			@min_date ||= self.map(&:date).min
		end

		# @return [String]
		# Error message depending on the missing transaction
		def invalid_message
			return 'No positive transaction' if inflow.empty?
			return 'No negative transaction' if outflows.empty?
		end

		def period
			@temporary_period || @period
		end

		def << arg
			super arg
			self.sort! { |x, y| x.date <=> y.date }
			self
		end

		# @return [Array]
		# @see #outflows
		# Selects all positives transactions from Cashflow
		def inflow
			self.select { |x| x.amount * first_transaction_direction < 0 }
		end

		# @return [Array]
		# @see #inflow
		# Selects all negatives transactions from Cashflow
		def outflows
			self.select { |x| x.amount * first_transaction_direction > 0 }
		end

		private

		# @param method [Symbol]
		# Choose a Method to call.
		# @return [Class]
		def choose_(method)
			case method
				when :bisection
					Bisection.new compact_cf
				when :newton_method
					NewtonMethod.new compact_cf
				else
					raise ArgumentError, "There is no method called #{method} "
			end
		end

		# @api private
		# Sorts the {Cashflow} by date ascending
		#   and finds the signal of the first transaction.
		# This implies the first transaction is a disbursement
		# @return [Integer]
		def first_transaction_direction
			# self.sort! { |x, y| x.date <=> y.date }
			@first_transaction_direction ||= self.first.amount / self.first.amount.abs
		end

		# Based on the direction of the first investment finds the multiple cash-on-cash
		# @example
		#   [100,100,-300] and [-100,-100,300] returns 1.5
		# @api private
		# @return [Float]
		def multiple
			inflow.sum(&:amount).abs / outflows.sum(&:amount).abs
		end

		def first_transaction_positive?
			first_transaction_direction > 0
		end

		# @api private
		# Counts how many years from first to last transaction in the cashflow
		# @return
		def periods_of_investment
			(max_date - min_date) / period
		end

	end

end
