# frozen_string_literal: true

# The classifier's return-type tables are claims about core Ruby;
# this spec executes them so a table entry can never drift from
# what the running Ruby does.
RSpec.describe Audition::Static::LiteralClassifier do
  def enumerables = [[3, 1, 2].freeze, {b: 2, a: 1}.freeze, (1..3)]

  def strings = ["a,b c\nd"]

  def call_with_defaults(receiver, name)
    method = receiver.method(name)
    args =
      case name
      when :grep, :grep_v then [Object]
      when :zip, :product then [[1]]
      when :take, :drop, :rotate, :values_at then [1]
      when :merge then [{}]
      when :except then [:a]
      when :split then [","]
      when :scan then [/./]
      else []
      end
    needs_block = %i[
      map collect flat_map collect_concat filter_map select filter
      reject partition sort_by take_while drop_while group_by
      transform_values transform_keys min_by max_by
    ].include?(name)
    if needs_block
      method.call(*args) { |*x| x.first }
    else
      method.call(*args)
    end
  end

  def each_sample(names, receivers)
    names.each do |name|
      receivers.each do |receiver|
        next unless receiver.respond_to?(name)

        yield name, receiver, call_with_defaults(receiver, name)
      end
    end
  end

  it "lists Array-returning methods that always allocate" do
    each_sample(described_class::FRESH_ARRAY_METHODS, enumerables) do |name, r, result|
      expect(result).to be_a(Array), "#{r.class}##{name}"
      expect(result).not_to be_frozen, "#{r.class}##{name}"
      expect(result).not_to equal(r), "#{r.class}##{name}"
    end
  end

  it "lists Hash-returning methods that always allocate" do
    each_sample(described_class::FRESH_HASH_METHODS, enumerables) do |name, r, result|
      expect(result).to be_a(Hash), "#{r.class}##{name}"
      expect(result).not_to be_frozen, "#{r.class}##{name}"
      expect(result).not_to equal(r), "#{r.class}##{name}"
    end
  end

  it "lists container-returning methods that always allocate" do
    names = described_class::FRESH_CONTAINER_METHODS
    each_sample(names, enumerables) do |name, r, result|
      expect(result).to be_a(Array).or(be_a(Hash)), "#{r.class}##{name}"
      expect(result).not_to be_frozen, "#{r.class}##{name}"
      expect(result).not_to equal(r), "#{r.class}##{name}"
    end
  end

  it "lists String methods that split into unfrozen strings" do
    names = described_class::FRESH_STRING_ARRAYS
    each_sample(names, strings) do |name, _r, result|
      expect(result).to be_a(Array), name.to_s
      expect(result).not_to be_frozen, name.to_s
      expect(result.flatten).to all(satisfy { |s| !s.frozen? }), name.to_s
    end
  end

  it "lists String methods that split into shareable elements" do
    names = described_class::SHAREABLE_ELEMENT_ARRAYS
    each_sample(names, strings) do |name, _r, result|
      expect(result).not_to be_frozen, name.to_s
      expect(Ractor.shareable?(result.freeze)).to be(true), name.to_s
    end
  end

  it "lists Method factories whose results never share" do
    described_class::METHOD_OBJECTS.each do |name|
      value = Module.public_send(name, :name)
      expect(Ractor.shareable?(value)).to be(false), name.to_s
      expect(Ractor.shareable?(value.freeze)).to be(false), name.to_s
    end
  end

  it "lists comparisons that return shareable values" do
    described_class::COMPARISONS.each do |name|
      next if name == :!

      value = 1.public_send(name, 2)
      expect(Ractor.shareable?(value)).to be(true), name.to_s
    end
    negated = !enumerables.first
    expect(Ractor.shareable?(negated)).to be(true)
  end

  it "lists arithmetic that keeps numerics numeric" do
    described_class::ARITHMETIC.each do |name|
      value = 12.public_send(name, 3)
      expect(value).to be_a(Numeric), name.to_s
      expect(Ractor.shareable?(value)).to be(true), name.to_s
    end
  end
end
