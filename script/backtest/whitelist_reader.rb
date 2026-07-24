# frozen_string_literal: true

module Backtest
  # The column-whitelist CSV reader (A6 privacy rail): builds row hashes from
  # ALLOWED column indices ONLY — non-allowed cells never materialize into
  # Ruby strings beyond the raw line split, and requesting a column outside
  # the allowlist raises KeyError. Allowlists that name an author-shaped
  # column are rejected at construction (defense in depth).
  class WhitelistReader
    BANNED_COLUMNS = /author|login|user|actor|email/i

    # Rows expose ONLY whitelisted columns; anything else is a KeyError.
    class Row
      def initialize(cells)
        @cells = cells
      end

      def [](key)
        @cells.fetch(key)
      end

      def key?(key)
        @cells.key?(key)
      end

      def to_h
        @cells.dup
      end
    end

    def initialize(path, allow:)
      banned = allow.grep(BANNED_COLUMNS)
      unless banned.empty?
        raise ArgumentError,
              "allowlist contains banned author-shaped column(s): #{banned.sort.join(', ')}"
      end

      @path = path
      @allow = allow.freeze
    end

    attr_reader :path, :allow

    # @return [Array<Row>]
    def rows
      @rows ||= begin
        lines = File.readlines(@path, chomp: true).reject(&:empty?)
        raise ArgumentError, "empty CSV at #{@path}" if lines.empty?

        header = self.class.split_line(lines.first)
        allowed_indices = header.each_index.select { |i| @allow.include?(header[i]) }

        lines.drop(1).map do |line|
          cells = self.class.split_line(line)
          picked = allowed_indices.each_with_object({}) do |i, acc|
            acc[header[i]] = cells[i]
          end
          Row.new(picked)
        end
      end
    end

    # Minimal RFC-4180 line splitter (quotes, escaped double-quotes, commas
    # inside quotes). stdlib `csv` left the default gem set in ruby 3.4 and
    # the no-new-gems posture holds — the frozen corpus files are plain
    # RFC-4180.
    def self.split_line(line)
      cells = []
      cell = +""
      in_quotes = false
      i = 0
      while i < line.length
        ch = line[i]
        if in_quotes
          if ch == '"'
            if line[i + 1] == '"'
              cell << '"'
              i += 1
            else
              in_quotes = false
            end
          else
            cell << ch
          end
        elsif ch == '"'
          in_quotes = true
        elsif ch == ","
          cells << cell
          cell = +""
        else
          cell << ch
        end
        i += 1
      end
      cells << cell
      cells
    end
  end
end
