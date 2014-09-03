# encoding: utf-8

# File:
#      modules/Bootloader.ycp
#
# Module:
#      Bootloader installation and configuration
#
# Summary:
#      Bootloader installation and configuration base module
#
# Authors:
#      Jiri Srain <jsrain@suse.cz>
#      Olaf Dabrunz <od@suse.de>
#
# $Id$
#
require "yast"

module Yast
  class BootloaderClass < Module
    def main
      Yast.import "UI"

      textdomain "bootloader"

      Yast.import "Arch"
      Yast.import "BootCommon"
      Yast.import "BootStorage"
      Yast.import "Installation"
      Yast.import "Initrd"
      Yast.import "Kernel"
      Yast.import "Mode"
      Yast.import "Progress"
      Yast.import "Stage"
      Yast.import "Storage"
      Yast.import "Directory"

      #fate 303395
      Yast.import "ProductFeatures"
      # Write is repeating again
      # Because of progress bar during inst_finish
      @repeating_write = false

      # installation proposal help variables

      # Configuration was changed during inst. proposal if true
      @proposed_cfg_changed = false

      # Cache for the installation proposal
      @cached_proposal = nil
      @cached_settings = {}

      # old vga value handling function

      # old value of vga parameter of default bootloader section
      @old_vga = nil

      # UI helping variables

      Yast.include self, "bootloader/routines/switcher.rb"
      Yast.include self, "bootloader/routines/popups.rb"


      # general functions

      @test_abort = nil
    end

    # Check whether abort was pressed
    # @return [Boolean] true if abort was pressed
    def testAbort
      return false if @test_abort == nil
      @test_abort.call
    end

    # bnc #419197 yast2-bootloader does not correctly initialise libstorage
    # Function try initialize yast2-storage
    # if other module used it then don't continue with initialize
    # @return [Boolean] true on success

    def checkUsedStorage
      if !Storage.InitLibstorage(true) && Mode.normal
        return false
      else
        return true
      end
    end

    # Export bootloader settings to a map
    # @return bootloader settings
    def Export
      ReadOrProposeIfNeeded()
      out = {
        "loader_type"    => getLoaderType,
        "initrd"         => Initrd.Export,
        "specific"       => blExport,
        "write_settings" => BootCommon.write_settings
      }
      loader_type = Ops.get_string(out, "loader_type")

      # export loader_device and selected_location only for bootloaders
      # that have not phased them out yet
      Ops.set(out, "loader_device", BootCommon.loader_device)
      Ops.set(out, "loader_location", BootCommon.selected_location)
      Builtins.y2milestone("Exporting settings: %1", out)
      deep_copy(out)
    end
    # Import settings from a map
    # @param [Hash] settings map of bootloader settings
    # @return [Boolean] true on success
    def Import(settings)
      settings = deep_copy(settings)
      Builtins.y2milestone("Importing settings: %1", settings)
      Reset()

      BootCommon.was_read = true
      BootCommon.was_proposed = true
      BootCommon.changed = true
      BootCommon.location_changed = true

      if settings["loader_type"] == ""
        settings["loader_type"] = nil
      end
      # if bootloader is not set, then propose it
      loader_type = settings["loader_type"] || BootCommon.getLoaderType(true)
      # Explitelly set it to ensure it is installed
      BootCommon.setLoaderType(loader_type)

      # import loader_device and selected_location only for bootloaders
      # that have not phased them out yet
      BootCommon.loader_device = Ops.get_string(settings, "loader_device", "")
      BootCommon.selected_location = Ops.get_string(
        settings,
        "loader_location",
        "custom"
      )
      # FIXME: obsolete for grub (but inactive through the outer "if" now anyway):
      # for grub, always correct the bootloader device according to
      # selected_location (or fall back to value of loader_device)
      if Arch.i386 || Arch.x86_64
        BootCommon.loader_device = BootCommon.GetBootloaderDevice
      end

      if Ops.get_map(settings, "initrd", {}) != nil
        Initrd.Import(Ops.get_map(settings, "initrd", {}))
      end
      ret = blImport(Ops.get_map(settings, "specific", {}))
      BootCommon.write_settings = Ops.get_map(settings, "write_settings", {})
      ret
    end
    # Read settings from disk
    # @return [Boolean] true on success
    def Read
      Builtins.y2milestone("Reading configuration")
      # run Progress bar
      stages = [
        # progress stage, text in dialog (short, infinitiv)
        _("Check boot loader"),
        # progress stage, text in dialog (short, infinitiv)
        _("Read partitioning"),
        # progress stage, text in dialog (short, infinitiv)
        _("Load boot loader settings")
      ]
      titles = [
        # progress step, text in dialog (short)
        _("Checking boot loader..."),
        # progress step, text in dialog (short)
        _("Reading partitioning..."),
        # progress step, text in dialog (short)
        _("Loading boot loader settings...")
      ]
      # dialog header
      Progress.New(
        _("Initializing Boot Loader Configuration"),
        " ",
        3,
        stages,
        titles,
        ""
      )

      Progress.NextStage
      return false if testAbort

      Progress.NextStage
      return false if !checkUsedStorage

      getLoaderType

      BootCommon.DetectDisks
      Progress.NextStage
      return false if testAbort

      ret = blRead(true, false)
      BootCommon.was_read = true
      @old_vga = getKernelParam(getDefaultSection, "vgamode")

      Progress.Finish
      return false if testAbort
      Builtins.y2debug("Read settings: %1", Export())
      ret
    end
    # Reset bootloader settings
    # @param [Boolean] init boolean true if basic initialization of system-dependent
    # settings should be done
    def ResetEx(init)
      return if Mode.autoinst
      Builtins.y2milestone("Reseting configuration")
      BootCommon.was_proposed = false
      BootCommon.was_read = false
      BootCommon.loader_device = ""
      #	BootCommon::setLoaderType (nil);
      BootCommon.changed = false
      BootCommon.location_changed = false
      #	BootCommon::other_bl = $[];
      BootCommon.files_edited = false
      BootCommon.write_settings = {}
      blReset(init)

      nil
    end

    # Reset bootloader settings
    def Reset
      ResetEx(true)
    end
    # Propose bootloader settings
    def Propose
      Builtins.y2milestone("Proposing configuration")
      # always have a current target map available in the log
      Builtins.y2milestone("unfiltered target map: %1", Storage.GetTargetMap)
      BootCommon.UpdateInstallationKernelParameters
      blPropose

      BootCommon.was_proposed = true
      BootCommon.changed = true
      BootCommon.location_changed = true
      BootCommon.partitioning_last_change = Storage.GetTargetChangeTime
      BootCommon.backup_mbr = true
      Builtins.y2milestone("Proposed settings: %1", Export())

      nil
    end


    # Display bootloader summary
    # @return a list of summary lines
    def Summary
      ret = []

      # F#300779 - Install diskless client (NFS-root)
      # kokso: additional warning that root partition is nfs type -> bootloader will not be installed

      device = BootCommon.getBootDisk
      if device == "/dev/nfs"
        ret = Builtins.add(
          ret,
          _(
            "The boot partition is of type NFS. Bootloader cannot be installed."
          )
        )
        Builtins.y2milestone(
          "Bootloader::Summary() -> Boot partition is nfs type, bootloader will not be installed."
        )
        return deep_copy(ret)
      end
      # F#300779 - end

      blSummary
    end

    # Update read settings to new version of configuration files
    def UpdateConfiguration
      # first run bootloader-specific update function
      blUpdate

      # remove no more needed Kernel modules from /etc/modules-load.d/
      ["cdrom", "ide-cd", "ide-scsi"].each do |kernel_module|
        Kernel.RemoveModuleToLoad(kernel_module) if Kernel.module_to_be_loaded?(kernel_module)
      end
      Kernel.SaveModulesToLoad

      nil
    end

    # Update the whole configuration
    # @return [Boolean] true on success
    def Update
      Write() # write also reads the configuration and updates it
    end

    # Process update actions needed before packages update starts
    def PreUpdate
      Builtins.y2milestone("Running bootloader pre-update stuff")

      nil
    end

    # Write bootloader settings to disk
    # @return [Boolean] true on success
    def Write
      ret = true

      if @repeating_write
        BootCommon.was_read = true
      else
        ReadOrProposeIfNeeded()
      end

      if Ops.get_boolean(BootCommon.write_settings, "save_all", false)
        BootCommon.save_all = true
      end
      if BootCommon.save_all
        BootCommon.changed = true
        BootCommon.location_changed = true
        Initrd.changed = true
      end

      Builtins.y2milestone("Writing bootloader configuration")

      # run Progress bar
      stages = [
        # progress stage, text in dialog (short)
        _("Create initrd"),
        # progress stage, text in dialog (short)
        _("Save boot loader configuration files"),
        # progress stage, text in dialog (short)
        _("Install boot loader")
      ]
      titles = [
        # progress step, text in dialog (short)
        _("Creating initrd..."),
        # progress step, text in dialog (short)
        _("Saving boot loader configuration files..."),
        # progress step, text in dialog (short)
        _("Installing boot loader...")
      ]
      # progress bar caption
      if Mode.normal
        # progress line
        Progress.New(
          _("Saving Boot Loader Configuration"),
          " ",
          stages.size,
          stages,
          titles,
          ""
        )
        Progress.NextStage
      else
        Progress.Title(Ops.get(titles, 0, ""))
      end

      params_to_save = {}

      new_vga = getKernelParam(getDefaultSection, "vgamode")
      if new_vga != @old_vga && new_vga != "false" && new_vga != "" &&
          new_vga != "ask"
        Initrd.setSplash(new_vga)
        Ops.set(params_to_save, "vgamode", new_vga) if Stage.initial
      end

      # save initrd
      if (Initrd.changed || !Mode.normal) &&
          !Ops.get_boolean(
            BootCommon.write_settings,
            "forbid_save_initrd",
            false
          )
        vga = getKernelParam(getDefaultSection, "vgamode")
        if vga != "false" && vga != "" && vga != "ask"
          Initrd.setSplash(vga)
          Ops.set(params_to_save, "vgamode", new_vga) if Stage.initial
        end
        ret = Initrd.Write
        BootCommon.changed = true
      end
      Builtins.y2error("Error occurred while creating initrd") if !ret

      BootCommon.changed = true if Mode.commandline

      if !(BootCommon.changed ||
          Ops.get_boolean(
            BootCommon.write_settings,
            "initrd_changed_externally",
            false
          ))
        Builtins.y2milestone("No bootloader cfg. file saving needed, exiting") 
        #	    return true;
      end

      if Mode.normal
        Progress.NextStage
      else
        Progress.NextStep if !@repeating_write
        Progress.Title(Ops.get(titles, 1, ""))
      end

      # Write settings to /etc/sysconfig/bootloader
      Builtins.y2milestone("Saving configuration files")
      lt = getLoaderType

      SCR.Write(path(".sysconfig.bootloader.LOADER_TYPE"), lt)
      SCR.Write(path(".sysconfig.bootloader"), nil)


      Ops.set(
        params_to_save,
        "additional_failsafe_params",
        BootCommon.GetAdditionalFailsafeParams
      )
      Ops.set(params_to_save, "installation_kernel_params", Kernel.GetCmdLine)
      if Stage.initial
        SCR.Write(
          path(".target.ycp"),
          "/var/lib/YaST2/bootloader.ycp",
          params_to_save
        )
      end

      return ret if getLoaderType == "none"

      #F#300779 - Install diskless client (NFS-root)
      #kokso: bootloader will not be installed
      device = BootCommon.getBootDisk

      if device == "/dev/nfs"
        Builtins.y2milestone(
          "Bootloader::Write() -> Boot partition is nfs type, bootloader will not be installed."
        )
        return ret
      end

      #F#300779 -end

      # save bootloader settings
      reinit = !Mode.normal
      Builtins.y2milestone(
        "Reinitialize bootloader library before saving: %1",
        reinit
      )
      ret = blSave(true, reinit, true) && ret

      if !ret
        Builtins.y2error("Error before configuration files saving finished")
      end

      if Mode.normal
        Progress.NextStage
      else
        Progress.NextStep if !@repeating_write
        Progress.Title(Ops.get(titles, 2, ""))
      end

      # call bootloader executable
      Builtins.y2milestone("Calling bootloader executable")
      ret = ret && blWrite
      if !ret
        Builtins.y2error("Installing bootloader failed")
        if writeErrorPopup
          @repeating_write = true
          res = Convert.to_map(
            WFM.call(
              "bootloader_proposal",
              ["AskUser", { "has_next" => false }]
            )
          )
          return Write() if Ops.get(res, "workflow_sequence") == :next
        end
      end

      ret
    end


    # Write bootloader settings during installation
    # @return [Boolean] true on success
    def WriteInstallation
      Builtins.y2milestone(
        "Writing bootloader configuration during installation"
      )
      ret = true

      if Ops.get_boolean(BootCommon.write_settings, "save_all", false)
        BootCommon.save_all = true
      end
      if BootCommon.save_all
        BootCommon.changed = true
        BootCommon.location_changed = true
        Initrd.changed = true
      end

      params_to_save = {}

      new_vga = getKernelParam(getDefaultSection, "vgamode")
      if new_vga != @old_vga && new_vga != "false" && new_vga != ""
        Initrd.setSplash(new_vga)
        Ops.set(params_to_save, "vgamode", new_vga) if Stage.initial
      end


      # save initrd
      if (Initrd.changed || !Mode.normal) &&
          !Ops.get_boolean(
            BootCommon.write_settings,
            "forbid_save_initrd",
            false
          )
        vga = getKernelParam(getDefaultSection, "vgamode")
        if vga != "false" && vga != ""
          Initrd.setSplash(vga)
          Ops.set(params_to_save, "vgamode", new_vga) if Stage.initial
        end
        ret = Initrd.Write
        BootCommon.changed = true
      end

      Builtins.y2error("Error occurred while creating initrd") if !ret

      Ops.set(
        params_to_save,
        "additional_failsafe_params",
        BootCommon.GetAdditionalFailsafeParams
      )
      Ops.set(params_to_save, "installation_kernel_params", Kernel.GetCmdLine)

      if Stage.initial
        SCR.Write(
          path(".target.ycp"),
          "/var/lib/YaST2/bootloader.ycp",
          params_to_save
        )
      end

      return ret if getLoaderType == "none"

      # F#300779 - Install diskless client (NFS-root)
      # kokso: bootloader will not be installed
      device = BootCommon.getBootDisk

      if device == "/dev/nfs"
        Builtins.y2milestone(
          "Bootloader::Write() -> Boot partition is nfs type, bootloader will not be installed."
        )
        return ret
      end

      # F#300779 -end

      # save bootloader settings
      reinit = !(Mode.update || Mode.normal)
      Builtins.y2milestone(
        "Reinitialize bootloader library before saving: %1",
        reinit
      )


      ret = blSave(true, reinit, true) && ret

      if !ret
        Builtins.y2error("Error before configuration files saving finished")
      end


      # call bootloader executable
      Builtins.y2milestone("Calling bootloader executable")
      ret = ret && blWrite
      if !ret
        Builtins.y2error("Installing bootloader failed")
        if writeErrorPopup
          @repeating_write = true
          res = Convert.to_map(
            WFM.call(
              "bootloader_proposal",
              ["AskUser", { "has_next" => false }]
            )
          )
          return Write() if Ops.get(res, "workflow_sequence") == :next
        end
      end
      ret
    end

    # return default section label
    # @return [String] default section label
    def getDefaultSection
      ReadOrProposeIfNeeded()
      BootCommon.globals["default"] || ""
    end

    # Get default section as proposed during installation
    # @return section that was proposed as default during installation,
    # if not known, return current default section if it is of type "image",
    # if not found return first linux section, if no present, return empty
    # string
    def getProposedDefaultSection
      ReadOrProposeIfNeeded()
      defaultv = ""
      first_image = ""
      default_image = ""
      Builtins.foreach(BootCommon.sections) do |s|
        title = Ops.get_string(s, "name", "")
        if Ops.get(s, "image") != nil
          first_image = title if first_image == ""
          default_image = title if title == getDefaultSection
        end
        if defaultv == "" && Ops.get_string(s, "original_name", "") == "linux"
          defaultv = title
        end
      end
      return defaultv if defaultv != ""
      return default_image if default_image != ""
      return first_image if first_image != ""
      ""
    end


    # get kernel parameters from bootloader configuration file
    # @param [String] section string section title, use DEFAULT for default section
    # @param [String] key string
    # @return [String] value, "false" if not present,
    # "true" if present key without value
    # @deprecated Use kernel_param instead
    def getKernelParam(section, key)
      ReadOrProposeIfNeeded()
      if section == "DEFAULT"
        section = getDefaultSection
      elsif section == "LINUX_DEFAULT"
        section = getProposedDefaultSection
      end
      return "" if section == nil
      params = Convert.to_map(BootCommon.getAnyTypeAttrib("kernel_params", {}))
      sectnum = -1
      index = -1
      Builtins.foreach(BootCommon.sections) do |s|
        index = Ops.add(index, 1)
        sectnum = index if Ops.get_string(s, "name", "") == section
      end
      return "" if sectnum == -1
      line = ""
      if Builtins.contains(["root", "vgamode"], key)
        return Ops.get_string(BootCommon.sections, [sectnum, key], "false")
      else
        line = Ops.get_string(BootCommon.sections, [sectnum, "append"], "")
        return BootCommon.getKernelParamFromLine(line, key)
      end
    end

    FLAVOR_KERNEL_LINE_MAP = {
      :common    => "append",
      :recovery  => "append_failsafe",
      :xen_guest => "xen_append",
      :xen_host  => "xen_kernel_append"
    }

    # Gets value for given parameter in kernel parameters for given flavor.
    # @note For grub1 it returns value for default section and its kernel parameter
    # @param [Symbol] flavor flavor of kernel, for possible values see #modify_kernel_param
    # @param [String] key of parameter on kernel command line
    # @returns [String,:missing,:present] Returns string for parameters with value,
    #   `:missing` if key is not there and `:present` for parameters without value.
    #
    # @example get crashkernel parameter to common kernel
    #   Bootloader.kernel_param(:common, "crashkernel")
    #   => "256M@64B"
    #
    # @example get cio_ignore parameter for recovery kernel when missing
    #   Bootloader.kernel_param(:recovery, "cio_ignore")
    #   => :missing
    #
    # @example get verbose parameter for xen_guest which is there
    #   Bootloader.kernel_param(:xen_guest, "verbose")
    #   => :present
    #

    def kernel_param(flavor, key)
      ReadOrProposeIfNeeded() # ensure we have some data

      kernel_line_key = FLAVOR_KERNEL_LINE_MAP[flavor]
      raise ArgumentError, "Unknown flavor #{flavor}" unless kernel_line_key

      line = BootCommon.globals[kernel_line_key]
      ret = BootCommon.getKernelParamFromLine(line, key)

      # map old api response to new one
      api_mapping = { "true" => :present, "false" => :missing }
      return api_mapping[ret] || ret
    end

    # Modify kernel parameters for installed kernels according to values
    # For grub1 for backward compatibility modify default section
    # @param [Array]  args parameters to modify. Last parameter is hash with keys
    #   and its values, keys are strings and values are `:present`, `:missing` or
    #   string value. Other parameters specify which kernel flavors are affected.
    #   Known values are:
    #     - `:common` for non-specific flavor
    #     - `:recovery` for fallback boot entries
    #     - `:xen_guest` for xen guest kernels
    #     - `:xen_host` for xen host kernels
    #
    # @example add crashkernel parameter to common kernel, xen guest and also recovery
    #   Bootloader.modify_kernel_params(:common, :recovery, :xen_guest, "crashkernel" => "256M@64M")
    #
    # @example same as before just with array passing
    #   targets = [:common, :recovery, :xen_guest]
    #   Bootloader.modify_kernel_params(targets, "crashkernel" => "256M@64M")
    #
    # @example remove cio_ignore parameter for common kernel only
    #   Bootloader.modify_kernel_params("cio_ignore" => :missing)
    #
    # @example add feature_a parameter and remove feature_b from xen host kernel
    #   Bootloader.modify_kernel_params(:xen_host, "cio_ignore" => :present)
    #
    def modify_kernel_params(*args)
      values = args.pop
      if !values.is_a? Hash
        raise ArgumentError, "Missing parameters to modify #{args.inspect}"
      end
      args = [:common] if args.empty? # by default change common kernels only
      args = args.first if args.first.is_a? Array # support array like syntax

      values.each do |key, value|
        next if key == "root" # grub2 do not support modify root
        if key == "vga"
          BootCommon.globals["vgamode"] = value == :remove ? "" : value
          next
        else
          kernel_lines = args.map do |a|
            FLAVOR_KERNEL_LINE_MAP[a] ||
              raise(ArgumentError, "Invalid argument #{a.inspect}")
          end
          kernel_lines.each do |line_key|
            BootCommon.globals[line_key] = BootCommon.setKernelParamToLine(BootCommon.globals[line_key], key, value)
          end
        end
        BootCommon.globals["__modified"] = "1"
        BootCommon.changed = true
      end
    end

    # Get currently used bootloader, detect if not set yet
    # @return [String] botloader type
    def getLoaderType
      BootCommon.getLoaderType(false)
    end

    # Set type of bootloader
    # Just a wrapper to BootCommon::setLoaderType
    # @param [String] bootloader string type of bootloader
    def setLoaderType(bootloader)
      BootCommon.setLoaderType(bootloader)

      nil
    end

    # Set section to boot on next reboot
    # @param section string section to boot
    # @return [Boolean] true on success
    def RunDelayedUpdates
      # perl-BL delayed section removal
      BootCommon.RunDelayedUpdates
      nil
    end

    # Set section to boot on next reboot
    # @param [String] section string section to boot
    # @return [Boolean] true on success
    def FlagOnetimeBoot(section)
      blFlagOnetimeBoot(section)
    end

    # Check whether settings were read or proposed, if not, decide
    # what to do and read or propose settings
    def ReadOrProposeIfNeeded
      if !(BootCommon.was_read || BootCommon.was_proposed)
        Builtins.y2milestone(
          "Stage::initial (): %1, update: %2, config: %3",
          Stage.initial,
          Mode.update,
          Mode.config
        )
        if Mode.config
          Builtins.y2milestone("Not reading settings in Mode::config ()")
          BootCommon.was_read = true
          BootCommon.was_proposed = true
        elsif Stage.initial && !Mode.update
          Propose()
        else
          progress_orig = Progress.set(false)
          Read()
          Progress.set(progress_orig)
          if Mode.update
            UpdateConfiguration()
            BootCommon.changed = true
            BootCommon.location_changed = true
          end
        end
      end

      nil
    end

    # Function update append -> add console to append
    #
    # @param map<string,any> boot section
    # @return [Hash{String => Object}] updated boot section
    def updateAppend(section)
      section = deep_copy(section)
      ret = deep_copy(section)
      if Ops.get_string(section, "append", "") != "" &&
          Ops.get_string(section, "console", "") != ""
        updated_append = BootCommon.UpdateSerialConsole(
          Ops.get_string(section, "append", ""),
          Ops.get_string(section, "console", "")
        )
        Ops.set(ret, "append", updated_append) if updated_append != nil
      end
      deep_copy(ret)
    end


    # Get entry from DMI data returned by .probe.bios.
    #
    # @param [Array<Hash>] bios_data: result of SCR::Read(.probe.bios)
    # @param [String] section: section name
    # @param [String] key: key in section
    # @return [String]: entry
    def DMIRead(bios_data, section, key)
      bios_data = deep_copy(bios_data)
      result = ""

      Builtins.foreach(Ops.get_list(bios_data, [0, "smbios"], [])) do |x|
        if Ops.get_string(x, "type", "") == section
          result = Ops.get_string(x, key, "")
          raise Break
        end
      end

      Builtins.y2milestone(
        "Bootloader::DMIRead(%1, %2) = %3",
        section,
        key,
        result
      )

      result
    end


    # Check if we run in a vbox vm.
    #
    # @param [Array<Hash>] bios_data: result of SCR::Read(.probe.bios)
    # @return [Boolean]: true if yast runs in a vbox vm
    def IsVirtualBox(bios_data)
      bios_data = deep_copy(bios_data)
      r = DMIRead(bios_data, "sysinfo", "product") == "VirtualBox"

      Builtins.y2milestone("Bootloader::IsVirtualBox = %1", r)

      r
    end


    # Check if we run in a hyperv vm.
    #
    # @param [Array<Hash>] bios_data: result of SCR::Read(.probe.bios)
    # @return [Boolean]: true if yast runs in a hyperv vm
    def IsHyperV(bios_data)
      bios_data = deep_copy(bios_data)
      r = DMIRead(bios_data, "sysinfo", "manufacturer") ==
        "Microsoft Corporation" &&
        DMIRead(bios_data, "sysinfo", "product") == "Virtual Machine"

      Builtins.y2milestone("Bootloader::IsHyperV = %1", r)

      r
    end


    # Copy initrd and kernel on the end of instalation
    # (1st stage)
    # @return [Boolean] on success
    # fate #303395 Use kexec to avoid booting between first and second stage
    # copy kernel and initrd to /var/lib/YaST
    # run kernel via kexec instead of reboot
    # if not success then reboot...
    def CopyKernelInird
      Builtins.y2milestone("CopyKernelInird: start copy kernel and inird")

      if Mode.live_installation
        Builtins.y2milestone("Running live_installation without using kexec")
        return true
      end

      if ProductFeatures.GetBooleanFeature("globals", "kexec_reboot") != true
        Builtins.y2milestone(
          "Option kexec_reboot is false. kexec will not be used."
        )
        return true
      end

      # check architecture for using kexec instead of reboot
      if Arch.ppc || Arch.ia64 || Arch.s390
        Builtins.y2milestone("Skip using of kexec on this architecture")
        return true
      end

      bios_data = Convert.convert(
        SCR.Read(path(".probe.bios")),
        :from => "any",
        :to   => "list <map>"
      )

      Builtins.y2milestone("CopyKernelInird::bios_data = %1", bios_data)

      if IsVirtualBox(bios_data)
        Builtins.y2milestone(
          "Installation run on VirtualBox, skip kexec loading"
        )
        return false
      end

      if IsHyperV(bios_data)
        Builtins.y2milestone("Installation run on HyperV, skip kexec loading")
        return false
      end

      # create default sections
      linux_default = BootCommon.CreateLinuxSection("linux")

      Builtins.y2milestone("linux_default: %1", linux_default)

      default_section = {}

      name = getDefaultSection
      # find default section in BootCommon::sections
      Builtins.foreach(BootCommon.sections) do |section|
        if Builtins.search(
            Builtins.tostring(Ops.get_string(section, "name", "")),
            name
          ) != nil &&
            Ops.get(section, "root") == Ops.get(linux_default, "root") &&
            Ops.get_string(section, "original_name", "") != "failsafe"
          Builtins.y2milestone("default section: %1", section)
          default_section = deep_copy(section)
        end
      end

      # create directory /var/lib/YaST2
      WFM.Execute(path(".local.mkdir"), "/var/lib/YaST2")

      # build command for copy kernel and initrd to /var/lib/YaST during instalation
      cmd = nil

      default_section = updateAppend(default_section)

      cmd = Builtins.sformat(
        "/bin/cp %1%2 %1%3 %4",
        Installation.destdir,
        Builtins.tostring(Ops.get_string(default_section, "image", "")),
        Builtins.tostring(Ops.get_string(default_section, "initrd", "")),
        Directory.vardir
      )

      Builtins.y2milestone("Command for copy: %1", cmd)
      out = Convert.to_map(WFM.Execute(path(".local.bash_output"), cmd))
      if Ops.get(out, "exit") != 0
        Builtins.y2error("Copy kernel and initrd failed, output: %1", out)
        return false
      end

      if Ops.get_string(default_section, "root", "") == ""
        Builtins.y2milestone("root is not defined in default section.")
        return false
      end

      if Ops.get_string(default_section, "vgamode", "") == ""
        Builtins.y2milestone("vgamode is not defined in default section.")
        return false
      end

      # flush kernel options into /var/lib/YaST/kernel_params
      cmd = Builtins.sformat(
        "echo \"root=%1 %2 vga=%3\" > %4/kernel_params",
        Builtins.tostring(Ops.get_string(default_section, "root", "")),
        Builtins.tostring(Ops.get_string(default_section, "append", "")),
        Builtins.tostring(Ops.get_string(default_section, "vgamode", "")),
        Directory.vardir
      )

      Builtins.y2milestone("Command for flushing kernel args: %1", cmd)
      out = Convert.to_map(WFM.Execute(path(".local.bash_output"), cmd))
      if Ops.get(out, "exit") != 0
        Builtins.y2error("Flushing kernel params failed, output: %1", out)
        return false
      end

      true
    end

    publish :function => :Export, :type => "map ()"
    publish :function => :Import, :type => "boolean (map)"
    publish :function => :Propose, :type => "void ()"
    publish :function => :Read, :type => "boolean ()"
    publish :function => :Reset, :type => "void ()"
    publish :function => :Write, :type => "boolean ()"
    publish :function => :FlagOnetimeBoot, :type => "boolean (string)"
    publish :function => :ReadOrProposeIfNeeded, :type => "void ()"
    publish :function => :getDefaultSection, :type => "string ()"
    publish :function => :getKernelParam, :type => "string (string, string)"
    publish :function => :getLoaderType, :type => "string ()"
    publish :variable => :proposed_cfg_changed, :type => "boolean"
    publish :variable => :cached_proposal, :type => "map"
    publish :variable => :cached_settings, :type => "map"
    publish :function => :blExport, :type => "map ()"
    publish :function => :blImport, :type => "boolean (map)"
    publish :function => :blRead, :type => "boolean (boolean, boolean)"
    publish :function => :blReset, :type => "void (boolean)"
    publish :function => :blPropose, :type => "void ()"
    publish :function => :blsection_types, :type => "list <string> ()"
    publish :function => :blSave, :type => "boolean (boolean, boolean, boolean)"
    publish :function => :blSummary, :type => "list <string> ()"
    publish :function => :blUpdate, :type => "void ()"
    publish :function => :blWrite, :type => "boolean ()"
    publish :function => :blWidgetMaps, :type => "map <string, map <string, any>> ()"
    publish :function => :blDialogs, :type => "map <string, symbol ()> ()"
    publish :function => :blFlagOnetimeBoot, :type => "boolean (string)"
    publish :variable => :test_abort, :type => "boolean ()"
    publish :function => :ResetEx, :type => "void (boolean)"
    publish :function => :Summary, :type => "list <string> ()"
    publish :function => :UpdateConfiguration, :type => "void ()"
    publish :function => :Update, :type => "boolean ()"
    publish :function => :PreUpdate, :type => "void ()"
    publish :function => :WriteInstallation, :type => "boolean ()"
    publish :function => :setLoaderType, :type => "void (string)"
    publish :function => :RunDelayedUpdates, :type => "void ()"
    publish :function => :CopyKernelInird, :type => "boolean ()"
  end

  Bootloader = BootloaderClass.new
  Bootloader.main
end
