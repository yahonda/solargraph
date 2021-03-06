describe Solargraph::Pin::Block do
  it 'strips prefixes from parameter names' do
    pin = Solargraph::Pin::Block.new(args: ['foo', '*bar', '&block'])
    expect(pin.parameter_names).to eq(['foo', 'bar', 'block'])
  end
end
