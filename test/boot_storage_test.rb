require_relative "test_helper"

Yast.import "BootStorage"

describe Yast::BootStorage do
  subject { Yast::BootStorage }
  describe ".Md2Partitions" do
    it "returns map with devices creating virtual device as key and bios id as value" do
      target_map_stub("storage_mdraid.yaml")
      result = subject.Md2Partitions("/dev/md1")
      expect(result).to include("/dev/vda1")
      expect(result).to include("/dev/vdb1")
      expect(result).to include("/dev/vdc1")
      expect(result).to include("/dev/vdd1")
    end

    it "returns empty map if device is not created from other devices" do
      target_map_stub("storage_mdraid.yaml")
      result = subject.Md2Partitions("/dev/vda1")
      expect(result).to be_empty
    end
  end

  describe ".possible_locations_for_stage1" do
    let(:possible_locations) { subject.possible_locations_for_stage1 }
    before do
      target_map_stub("storage_mdraid.yaml")
      allow(Yast::Arch).to receive(:s390).and_return(false) # be arch agnostic
      allow(Yast::Storage).to receive(:GetDefaultMountBy).and_return(:device)
      allow(Yast::Storage).to receive(:GetContVolInfo).and_return(false)
    end

    it "returns list of kernel devices that can be used as stage1 for bootloader" do
      expect(possible_locations).to be_a(Array)
    end

    it "returns also physical disks" do
      expect(possible_locations).to include("/dev/vda")
    end

    it "returns all partitions suitable for stage1" do
      expect(possible_locations).to include("/dev/vda1")
    end

    it "do not list partitions marked for delete" do
      partition_to_delete = Yast::Storage.GetTargetMap["/dev/vda"]["partitions"].first
      partition_to_delete["delete"] = true

      expect(possible_locations).to_not include(partition_to_delete["device"])
    end
  end

  describe ".real_disks_for_partition" do
    before do
      mock_disk_partition
    end

    it "returns unique list of disk on which partitions lives" do
      target_map_stub("storage_mdraid.yaml")

      result = subject.real_disks_for_partition("/dev/vda1")
      expect(result).to include("/dev/vda")
    end

    it "can handle md raid" do
      target_map_stub("storage_mdraid.yaml")

      result = subject.real_disks_for_partition("/dev/md1")
      expect(result).to include("/dev/vda")
      expect(result).to include("/dev/vdb")
      expect(result).to include("/dev/vdc")
      expect(result).to include("/dev/vdd")
    end

    it "can handle LVM" do
      target_map_stub("storage_lvm.yaml")

      result = subject.real_disks_for_partition("/dev/system/root")
      expect(result).to include("/dev/vda")

      # do not crash if target map do not contain devices_add(bnc#891070)
      target_map_stub("storage_lvm_without_devices_add.yaml")

      result = subject.real_disks_for_partition("/dev/system/root")
      expect(result).to include("/dev/vda")
    end
  end

  describe ".multipath_mapping" do
    before do
      mock_disk_partition
      # force reinit every time
      allow(subject).to receive(:checkCallingDiskInfo).and_return(true)
      # mock getting mount points as it need whole libstorage initialization
      allow(Yast::Storage).to receive(:GetMountPoints).and_return("/" => "/dev/vda1")
      # mock for same reason getting udev mapping
      allow(::Bootloader::UdevMapping).to receive(:to_mountby_device) do |arg|
        arg
      end
    end

    it "returns empty map if there is no multipath" do
      target_map_stub("storage_lvm.yaml")

      # init variables
      subject.InitDiskInfo
      expect(subject.multipath_mapping).to eq({})
    end

    it "returns map of kernel names for disk devices to multipath devices associated with it" do
      target_map_stub("many_disks.yaml")

      # init variables
      subject.InitDiskInfo
      expect(subject.multipath_mapping["/dev/sda"]).to eq "/dev/mapper/3600508b1001c9a84c91492de27962d57"
    end
  end

  describe ".detect_disks" do
    before do
      mock_disk_partition
      target_map_stub("storage_lvm.yaml")

      allow(Yast::Storage).to receive(:GetMountPoints).and_return(
        "/"     => ["/dev/vda1"],
        "/boot" => ["/dev/vda2"]
      )
      allow(Yast::Storage).to receive(:GetContVolInfo).and_return(false)
    end

    it "fills RootPartitionDevice variable" do
      subject.RootPartitionDevice = nil

      subject.detect_disks

      expect(subject.RootPartitionDevice).to eq "/dev/vda1"
    end

    it "fills BootPartitionDevice variable" do
      subject.BootPartitionDevice = nil

      subject.detect_disks

      expect(subject.BootPartitionDevice).to eq "/dev/vda2"
    end

    it "sets ExtendedPartitionDevice variable to nil if boot is not logical" do
      subject.ExtendedPartitionDevice = nil

      subject.detect_disks

      expect(subject.ExtendedPartitionDevice).to eq nil
    end

    # need target map with it
    it "sets ExtendedPartitionDevice variable to extended partition if boot is logical"

    it "raises exception if there is no mount point for root" do
      allow(Yast::Storage).to receive(:GetMountPoints).and_return({})

      expect { subject.detect_disks }.to raise_error
    end

    it "sets BootStorage.mbr_disk" do
      expect(subject).to receive(:find_mbr_disk).and_return("/dev/vda")

      subject.detect_disks

      expect(subject.mbr_disk).to eq "/dev/vda"
    end
  end

  describe ".devices_for_redundant_boot" do
    # TODO: proper target map with 2 partitions in raid
    it "returns devices that can be used for redundant boot"
  end

  describe ".available_swap_partitions" do
    it "returns map of swap partitions and their size" do
      target_map_stub("storage_lvm.yaml")
      expect(subject.available_swap_partitions).to eq(
        "/dev/vda2" => 1_026_048
      )
    end

    it "returns crypt device name for encrypted swap" do
      target_map_stub("storage_encrypted.yaml")
      expect(subject.available_swap_partitions).to eq(
        "/dev/mapper/cr_swap" => 2_096_482
      )
    end
  end
end
