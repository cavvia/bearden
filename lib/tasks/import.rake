require 'csv'
require 'open-uri'

desc 'Import csv file'
task :import_csv, [:source_name, :url] => :environment do |_, args|
  url = args[:url]
  stringio = open(url)
  stringio.set_encoding Encoding::UTF_8
  data = stringio.read

  source = Source.find_by name: args[:source_name]
  abort 'Source not found' unless source
  import = source.imports.create(
    description: "importing file: #{url}",
    transformer: CsvTransformer
  )

  CSV.parse(data, headers: true) do |row|
    input = import.raw_inputs.create data: row.to_h
    RawInputTransformJob.perform_later input.id
  end

  puts "import #{import.id}"
end
