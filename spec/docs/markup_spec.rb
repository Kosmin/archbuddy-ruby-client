# frozen_string_literal: true

# v0.15 P3-T12 (I11): no tool-call markup may survive in any committed doc.
# The pattern is CONSTRUCTED from fragments ([S:F14] self-clean) so this spec
# file itself never contains the literal token sequences it hunts.
RSpec.describe "committed docs carry no tool-call markup (I11)" do
  MARKUP_ROOT = File.expand_path("../..", __dir__)

  # %r{</(content|invoke)>|<parameter } — assembled, never spelled.
  MARKUP_PATTERN = Regexp.new(
    ["<", "/", "(content|invoke)", ">"].join +
    "|" +
    ["<", "parameter", " "].join
  )

  it "scans every committed markdown file (>= 6-file floor) and finds nothing" do
    files = (Dir[File.join(MARKUP_ROOT, "*.md")] +
             Dir[File.join(MARKUP_ROOT, "docs", "**", "*.md")]).sort
    # An empty glob would vacuously pass — pin the repo's known doc count.
    expect(files.size).to be >= 6

    files.each do |path|
      matches = File.read(path, encoding: "UTF-8").scan(MARKUP_PATTERN)
      expect(matches).to be_empty,
                         "#{path.sub("#{MARKUP_ROOT}/", '')} contains tool-call markup: #{matches.first.inspect}"
    end
  end
end
