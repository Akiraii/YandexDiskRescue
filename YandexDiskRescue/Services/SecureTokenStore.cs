using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
namespace YandexDiskRescue.Services;
public static class SecureTokenStore
{
    private static string PathName => Path.Combine(JobStore.Root,"config","token.dat");
    public static void Save(string token)
    {
        var dir = Path.GetDirectoryName(PathName)!; Directory.CreateDirectory(dir);
        var sec = new DirectorySecurity(); sec.SetAccessRuleProtection(true,false);
        sec.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
        new DirectoryInfo(dir).SetAccessControl(sec);
        File.WriteAllBytes(PathName,ProtectedData.Protect(Encoding.UTF8.GetBytes(token),null,DataProtectionScope.CurrentUser));
    }
    public static string? Read() => File.Exists(PathName) ? Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(PathName),null,DataProtectionScope.CurrentUser)) : null;
    public static void Delete() { if(File.Exists(PathName)) File.Delete(PathName); }
}
