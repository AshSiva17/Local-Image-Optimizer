require "json"
args = ARGV.each_slice(2).to_h
input = args.fetch("--input")
output = args.fetch("--output")
mode = File.read(input)
File.open(input + '.runs', 'a') { |f| f.write('x') }
sleep 0.3 if mode == 'slow'
if mode.include?("corrupt") || mode == 'crash'
  File.binwrite(output, 'partial')
  warn "Failed to decode input image."
  exit 42
end
File.binwrite(output, "optimized-image") unless mode == 'nooutput'
sleep 60 if mode == 'hang'
if mode == 'malformed'
  puts 'not json'
else
  puts({ input: input, output: output, width: 1800, height: 900, format: args["--format"] == 'keep' ? 'png' : args["--format"] }.to_json)
end
