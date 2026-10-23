import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
public class PasswordHash {public static void main(String[] args)throws Exception {String password=new String(System.in.readAllBytes(),java.nio.charset.StandardCharsets.UTF_8).trim();if(password.length()<12)throw new IllegalArgumentException();System.out.print(new BCryptPasswordEncoder().encode(password));}}
