# frozen_string_literal: true

require 'base64'

describe LokaliseManager::TaskDefinitions::Exporter do
  let(:filename) { 'en.yml' }
  let(:path) { "#{Dir.getwd}/locales/nested/#{filename}" }
  let(:relative_name) { "nested/#{filename}" }
  let(:project_id) { ENV['LOKALISE_PROJECT_ID'] }
  let(:described_object) do
    described_class.new project_id: project_id,
                        api_token: ENV['LOKALISE_API_TOKEN'],
                        max_retries_export: 2
  end

  context 'with many translation files' do
    before :all do
      add_translation_files! with_ru: true, additional: 5
    end

    after :all do
      rm_translation_files
    end

    describe '.export!' do
      it 'sends a proper API request and handles rate limiting' do
        process = nil

        VCR.use_cassette('upload_files_multiple') do
          expect(-> { process = described_object.export!.first }).to output(/complete!/).to_stdout
        end

        expect(process.project_id).to eq(project_id)
        expect(process.status).to eq('queued')
      end

      it 'handles too many requests' do
        allow(described_object).to receive(:sleep).and_return(0)

        fake_client = instance_double('Lokalise::Client')
        allow(fake_client).to receive(:upload_file).with(any_args).and_raise(Lokalise::Error::TooManyRequests)
        allow(described_object).to receive(:api_client).and_return(fake_client)

        expect(-> { described_object.export! }).to raise_error(Lokalise::Error::TooManyRequests, /Gave up after 2 retries/i)

        expect(described_object).to have_received(:sleep).exactly(2).times
        expect(described_object).to have_received(:api_client).exactly(3).times
        expect(fake_client).to have_received(:upload_file).exactly(3).times
      end
    end
  end

  context 'with one translation file' do
    before :all do
      add_translation_files!
    end

    after :all do
      rm_translation_files
    end

    describe '.export!' do
      it 'sends a proper API request but does not output anything when silent_mode is enabled' do
        allow(described_object.config).to receive(:silent_mode).and_return(true)

        process = nil

        VCR.use_cassette('upload_files') do
          expect(-> { process = described_object.export!.first }).not_to output(/complete!/).to_stdout
        end

        expect(process.status).to eq('queued')
        expect(described_object.config).to have_received(:silent_mode).at_most(1).times
      end

      it 'sends a proper API request' do
        process = VCR.use_cassette('upload_files') do
          described_object.export!
        end.first

        expect(process.project_id).to eq(project_id)
        expect(process.status).to eq('queued')
      end

      it 'sends a proper API request when a different branch is provided' do
        allow(described_object.config).to receive(:branch).and_return('develop')

        process = VCR.use_cassette('upload_files_branch') do
          described_object.export!
        end.first

        expect(described_object.config).to have_received(:branch).at_most(2).times
        expect(process.project_id).to eq(project_id)
        expect(process.status).to eq('queued')
      end

      it 'halts when the API key is not set' do
        allow(described_object.config).to receive(:api_token).and_return(nil)

        expect(-> { described_object.export! }).to raise_error(LokaliseManager::Error, /API token is not set/i)
        expect(described_object.config).to have_received(:api_token)
      end

      it 'halts when the project_id is not set' do
        allow_project_id described_object, nil do
          expect(-> { described_object.export! }).to raise_error(LokaliseManager::Error, /ID is not set/i)
        end
      end
    end

    describe '.each_file' do
      it 'yield proper arguments' do
        expect { |b| described_object.send(:each_file, &b) }.to yield_with_args(
          Pathname.new(path),
          Pathname.new(relative_name)
        )
      end
    end

    describe '.opts' do
      let(:base64content) { Base64.strict_encode64(File.read(path).strip) }

      it 'generates proper options' do
        resulting_opts = described_object.send(:opts, path, relative_name)

        expect(resulting_opts[:data]).to eq(base64content)
        expect(resulting_opts[:filename]).to eq(relative_name)
        expect(resulting_opts[:lang_iso]).to eq('en')
      end

      it 'allows to redefine options' do
        allow(described_object.config).to receive(:export_opts).and_return({
                                                                             detect_icu_plurals: true,
                                                                             convert_placeholders: true
                                                                           })

        resulting_opts = described_object.send(:opts, path, relative_name)

        expect(described_object.config).to have_received(:export_opts)
        expect(resulting_opts[:data]).to eq(base64content)
        expect(resulting_opts[:filename]).to eq(relative_name)
        expect(resulting_opts[:lang_iso]).to eq('en')
        expect(resulting_opts[:detect_icu_plurals]).to be true
        expect(resulting_opts[:convert_placeholders]).to be true
      end
    end
  end

  context 'with two translation files' do
    let(:filename_ru) { 'ru.yml' }
    let(:path_ru) { "#{Dir.getwd}/locales/#{filename_ru}" }

    before :all do
      add_translation_files! with_ru: true
    end

    after :all do
      rm_translation_files
    end

    describe '.export!' do
      it 're-raises export errors' do
        allow_project_id described_object, '542886116159f798720dc4.94769464'

        VCR.use_cassette('upload_files_error') do
          expect { described_object.export! }.to raise_error(Lokalise::Error::BadRequest, /Unknown `lang_iso`/)
        end
      end
    end

    describe '.opts' do
      let(:base64content_ru) { Base64.strict_encode64(File.read(path_ru).strip) }

      it 'generates proper options' do
        resulting_opts = described_object.send(:opts, path_ru, filename_ru)

        expect(resulting_opts[:data]).to eq(base64content_ru)
        expect(resulting_opts[:filename]).to eq(filename_ru)
        expect(resulting_opts[:lang_iso]).to eq('ru_RU')
      end
    end

    describe '.each_file' do
      it 'yields every translation file' do
        expect { |b| described_object.send(:each_file, &b) }.to yield_successive_args(
          [
            Pathname.new(path),
            Pathname.new(relative_name)
          ],
          [
            Pathname.new(path_ru),
            Pathname.new(filename_ru)
          ]
        )
      end

      it 'does not yield files that have to be skipped' do
        allow(described_object.config).to receive(:skip_file_export).twice.and_return(
          ->(f) { f.split[1].to_s.include?('ru') }
        )
        expect { |b| described_object.send(:each_file, &b) }.to yield_successive_args(
          [
            Pathname.new(path),
            Pathname.new(relative_name)
          ]
        )

        expect(described_object.config).to have_received(:skip_file_export).twice
      end
    end
  end
end