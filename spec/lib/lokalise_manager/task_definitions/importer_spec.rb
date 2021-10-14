# frozen_string_literal: true

describe LokaliseManager::TaskDefinitions::Importer do
  let(:described_object) do
    described_class.new project_id: project_id,
                        api_token: ENV['LOKALISE_API_TOKEN'],
                        max_retries_import: 2
  end
  let(:loc_path) { described_object.config.locales_path }
  let(:project_id) { ENV['LOKALISE_PROJECT_ID'] }
  let(:local_trans) { "#{Dir.getwd}/spec/fixtures/trans.zip" }
  let(:faulty_trans) { "#{Dir.getwd}/spec/fixtures/faulty_trans.zip" }

  describe '.open_and_process_zip' do
    it 're-raises errors during file processing' do
      expect(-> { described_object.send(:open_and_process_zip, faulty_trans) }).
        to raise_error(Psych::DisallowedClass, /Error when trying to process fail\.yml/)
    end

    it 're-raises errors during file opening' do
      expect(-> { described_object.send(:open_and_process_zip, 'http://fake.url/wrong/path.zip') }).
        to raise_error(SocketError, /Failed to open TCP connection/)
    end
  end

  describe '.download_files' do
    it 'returns a proper download URL' do
      response = VCR.use_cassette('download_files') do
        described_object.send :download_files
      end

      expect(response['project_id']).to eq('672198945b7d72fc048021.15940510')
      expect(response['bundle_url']).to include('s3-eu-west-1.amazonaws.com')
      expect(described_object.api_client.enable_compression).to eq(true)
    end

    it 're-raises errors during file download' do
      allow_project_id described_object, 'invalid'

      VCR.use_cassette('download_files_error') do
        expect(-> { described_object.send :download_files }).
          to raise_error(Lokalise::Error::BadRequest, /Invalid `project_id` parameter/)
      end
    end
  end

  describe '.import!' do
    context 'with errors' do
      it 'handles too many requests' do
        allow(described_object).to receive(:sleep).and_return(0)

        fake_client = instance_double('Lokalise::Client')
        allow(fake_client).to receive(:download_files).and_raise(Lokalise::Error::TooManyRequests)
        allow(described_object).to receive(:api_client).and_return(fake_client)

        expect(-> { described_object.import! }).to raise_error(Lokalise::Error::TooManyRequests, /Gave up after 2 retries/i)

        expect(described_object).to have_received(:sleep).exactly(2).times
        expect(described_object).to have_received(:api_client).exactly(3).times
        expect(fake_client).to have_received(:download_files).exactly(3).times
      end

      it 'halts when the API key is not set' do
        allow(described_object.config).to receive(:api_token).and_return(nil)
        expect(-> { described_object.import! }).to raise_error(LokaliseManager::Error, /API token is not set/i)
        expect(described_object.config).to have_received(:api_token)
        expect(count_translations).to eq(0)
      end

      it 'halts when the project_id is not set' do
        allow_project_id described_object, nil do
          expect(-> { described_object.import! }).to raise_error(LokaliseManager::Error, /ID is not set/i)
          expect(count_translations).to eq(0)
        end
      end
    end

    context 'when directory is empty' do
      before do
        mkdir_locales
        rm_translation_files
      end

      after :all do
        rm_translation_files
      end

      it 'runs import successfully for local files' do
        allow(described_object).to receive(:download_files).and_return(
          {
            'project_id' => '123.abc',
            'bundle_url' => local_trans
          }
        )

        expect(described_object.import!).to be true

        expect(count_translations).to eq(4)
        expect(described_object).to have_received(:download_files)
        expect_file_exist loc_path, 'en/nested/main_en.yml'
        expect_file_exist loc_path, 'en/nested/deep/secondary_en.yml'
        expect_file_exist loc_path, 'ru/main_ru.yml'
      end

      it 'runs import successfully' do
        result = VCR.use_cassette('import') do
          described_object.import!
        end

        expect(result).to be true

        expect(count_translations).to eq(8)
        expect_file_exist loc_path, 'en.yml'
        expect_file_exist loc_path, 'ru.yml'
      end
    end

    context 'when directory is not empty and safe mode enabled' do
      let(:safe_mode_obj) do
        described_class.new project_id: project_id,
                            api_token: ENV['LOKALISE_API_TOKEN'],
                            import_safe_mode: true
      end

      before :all do
        mkdir_locales
      end

      before do
        rm_translation_files
        add_translation_files!
      end

      after :all do
        rm_translation_files
      end

      it 'import proceeds when the user agrees' do
        allow(safe_mode_obj).to receive(:download_files).and_return(
          {
            'project_id' => '123.abc',
            'bundle_url' => local_trans
          }
        )

        allow($stdin).to receive(:gets).and_return('Y')
        expect(-> { safe_mode_obj.import! }).to output(/is not empty/).to_stdout

        expect(count_translations).to eq(5)
        expect($stdin).to have_received(:gets)
        expect(safe_mode_obj).to have_received(:download_files)
        expect_file_exist loc_path, 'en/nested/main_en.yml'
        expect_file_exist loc_path, 'en/nested/deep/secondary_en.yml'
        expect_file_exist loc_path, 'ru/main_ru.yml'
      end

      it 'import halts when a user chooses not to proceed' do
        allow(safe_mode_obj).to receive(:download_files).at_most(0).times
        allow($stdin).to receive(:gets).and_return('N')
        expect(-> { safe_mode_obj.import! }).to output(/is not empty/).to_stdout

        expect(safe_mode_obj).not_to have_received(:download_files)
        expect($stdin).to have_received(:gets)
        expect(count_translations).to eq(1)
      end
    end
  end
end
